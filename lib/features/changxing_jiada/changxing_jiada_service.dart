import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/cas_routed_access.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/network/dio_client.dart';
import 'changxing_jiada_model.dart';
import 'changxing_jiada_token_binding.dart';

class ChangxingAuthExpiredException implements Exception {
  ChangxingAuthExpiredException([this.message = '畅行嘉大登录已失效，请重新登录']);

  final String message;

  @override
  String toString() => message;
}

class ChangxingCasLoginException implements Exception {
  ChangxingCasLoginException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// CAS session 无效，需要重新登录一卡通。
class ChangxingNeedUnifiedAuthException implements Exception {
  @override
  String toString() => '一卡通登录已失效，请重新登录';
}

@immutable
class ChangxingSubmitRequest {
  const ChangxingSubmitRequest({required this.path, required this.payload});

  final String path;
  final Map<String, dynamic> payload;
}

class ChangxingJiadaService {
  ChangxingJiadaService._() : _tokenBinding = ChangxingTokenBinding();

  static final ChangxingJiadaService instance = ChangxingJiadaService._();

  /// 直连形态的基址；实际请求一律经 [CasRoute.url] 按本次选路重建
  /// （校外自动改写为 WebVPN 代理地址），不读写全局 `ZhengfangAuth.mode`。
  static const _baseUrl = 'https://zhx.zjxu.edu.cn/api';
  static const _casLoginUrl = '$_baseUrl/cas_wap_login';
  static const _unifiedAuthLoginUrl = 'https://newca.zjxu.edu.cn/cas/login';

  /// 一次 CAS 登录的总预算（含网关会话、逐跳跟随与一次恢复）。
  static const _loginBudget = Duration(seconds: 30);

  /// 测试用：缩短登录总预算（生产恒为 [_loginBudget]）。
  @visibleForTesting
  Duration? debugLoginBudget;

  /// 选路缓存有效期：API 调用不必每次重验 CAS service / 网关会话。
  static const _routeTtl = Duration(seconds: 60);

  /// GET 手动跟随重定向的最大跳数。
  static const _maxApiRedirects = 5;

  /// token 的 owner 绑定 / 持久化（fail closed），见 [ChangxingTokenBinding]。
  final ChangxingTokenBinding _tokenBinding;

  /// 最近一次成功的选路（绑定发起时身份，短期有效）。
  _RouteLease? _routeLease;

  /// 同身份并发 API 调用合并到同一次 prepare，避免重复建网关会话。
  _RouteFlight? _routeFlight;

  bool get hasToken => _tokenBinding.hasToken;

  /// 读取归属当前统一认证账号的落盘 token；CAS 身份未就绪时不标记已恢复，
  /// 页面在身份就绪后会再次调用，仍能绑定到正确 owner。
  Future<void> restoreSession() => _tokenBinding.restore();

  Future<void> logout() => _tokenBinding.clear();

  /// 测试用：新存储 key（单条 JSON envelope）。
  @visibleForTesting
  static const tokenStorageKeyV2 = ChangxingTokenBinding.storageKeyV2;

  /// 测试用：旧的无 owner key（一律按不可用处理）。
  @visibleForTesting
  static const legacyTokenStorageKey = ChangxingTokenBinding.legacyStorageKey;

  /// 通过 CAS SSO 登录畅行嘉大。
  /// 前提：用户已通过 UnifiedAuthService 完成一卡通登录；校内直连、校外经
  /// WebVPN 由 [CasRoutedAccess] 按目标 origin 选路（不读写全局模式）。
  /// 全程绑定发起时的 owner + `sessionRevision`：每个 await 边界之后复核，
  /// 任一环节发现身份变化即放弃，且**绝不**把旧身份的 token 写入新会话。
  Future<void> loginViaCas() async {
    final owner = _tokenBinding.currentOwner;
    final revisionAtStart = UnifiedAuthService.instance.sessionRevision;
    if (owner == null) {
      // 没有可信的统一认证身份：token 无归属可绑，不发起无主 SSO。
      throw ChangxingNeedUnifiedAuthException();
    }

    await DioClient.instance.ensureInitialized();
    final dio = DioClient.instance.unifiedAuthDio;

    void ensureIdentityCurrent() {
      if (_tokenBinding.isCurrent(owner, revisionAtStart)) return;
      AppLogger.instance.auth(LogLevel.warn, '畅行嘉大 CAS 登录放弃：统一认证身份或会话修订已变化');
      throw ChangxingCasLoginException('登录状态已变化，请重试');
    }

    ensureIdentityCurrent();

    // 统一认证失效时 broker 可能已撤销会话（身份随之变空）：此时应引导
    // 重新登录；只有已切换到另一身份（仍处于登录态）才算「状态已变化」。
    void ensureNotSwitched() {
      if (_tokenBinding.isCurrent(owner, revisionAtStart)) return;
      if (!UnifiedAuthService.instance.isLoggedIn) return;
      ensureIdentityCurrent();
    }

    final cancelToken = CancelToken();
    final budget = debugLoginBudget ?? _loginBudget;
    final deadline = DateTime.now().add(budget);
    // getResource / prepare 返回时会取消各自的预算计时器，之后的 /getToken
    // 不再受约束：这里持有覆盖整次登录的计时器，到期统一取消共享 token。
    final budgetTimer = Timer(budget, () {
      if (!cancelToken.isCancelled) {
        cancelToken.cancel('changxing login budget exceeded');
      }
    });
    try {
      // 1. 会话确认 + 选路（WebVPN 时先补网关会话）。
      final route = await CasRoutedAccess.prepare(
        service: CasService.changxing,
        targetUrl: _casLoginUrl,
        cancelToken: cancelToken,
        deadline: deadline,
      );
      ensureIdentityCurrent();

      // 2. 发起 CAS 登录并在重定向链里提取 tokenId（命中即停，不消费后续 ticket）。
      // 命中登录 bounce 时只做一次恢复 + 重试，仍失效则引导重新登录一卡通。
      String? tokenId;
      for (var attempt = 0; ; attempt++) {
        try {
          tokenId = await _fetchTokenId(
            route,
            cancelToken: cancelToken,
            deadline: deadline,
          );
          ensureIdentityCurrent();
          break;
        } on CasAuthExpiredException {
          ensureNotSwitched();
          if (attempt >= 1) {
            AppLogger.instance.auth(LogLevel.warn, '畅行嘉大：统一认证会话已失效，需要重新登录一卡通');
            throw ChangxingNeedUnifiedAuthException();
          }
          await CasRoutedAccess.recover(
            route,
            service: CasService.changxing,
            cancelToken: cancelToken,
            deadline: deadline,
          );
          ensureIdentityCurrent();
        }
      }

      if (tokenId == null || tokenId.isEmpty) {
        AppLogger.instance.auth(LogLevel.warn, '畅行嘉大：SSO 链路结束但未获取到 tokenId');
        throw ChangxingCasLoginException('畅行嘉大登录未完成，请稍后重试');
      }

      // 3. 用 tokenId 换取 JWT token。
      final tokenResp = await dio.getUri<dynamic>(
        Uri.parse(route.url('$_baseUrl/getToken'))
            .replace(queryParameters: {'tokenId': tokenId}),
        cancelToken: cancelToken,
        options: _apiOptions(headers: {'token': '0'}),
      );
      ensureIdentityCurrent();

      final Map<String, dynamic> json;
      try {
        json = _jsonOrBounce(tokenResp);
      } on _ApiLoginBounce {
        _routeLease = null;
        throw ChangxingCasLoginException('畅行嘉大登录未完成，请稍后重试');
      }
      final data = json['data'] as Map<String, dynamic>? ?? {};
      final code = data['code']?.toString() ?? '';
      if (code != '20000') {
        final msg = data['msg']?.toString() ?? '获取 token 失败';
        throw ChangxingCasLoginException(msg);
      }

      final jwtToken = data['token']?.toString().trim() ?? '';
      if (jwtToken.isEmpty) {
        throw ChangxingCasLoginException('CAS 认证成功但未获取到 token');
      }

      // 写入前最后一次复核：身份已变化则拒绝保存（含绑定 owner）。
      final saved = await _tokenBinding.saveIfCurrent(
        token: jwtToken,
        owner: owner,
        revision: revisionAtStart,
      );
      if (!saved) {
        AppLogger.instance.auth(LogLevel.warn, '畅行嘉大 CAS 登录放弃：写入前身份已变化');
        throw ChangxingCasLoginException('登录状态已变化，请重试');
      }
      // 本次选路已被完整链路验证：供后续 API 调用短期复用。
      _routeLease = _RouteLease(
        route: route,
        owner: owner,
        revision: revisionAtStart,
        at: DateTime.now(),
      );
      AppLogger.instance.auth(LogLevel.info, '畅行嘉大 CAS SSO 登录成功');
    } on CasAuthExpiredException {
      // prepare / recover 明确判定统一认证失效（broker 对显式失效的既有
      // 处理可能已撤销会话）。本层不清全局会话、不 markLoggedOut。
      ensureNotSwitched();
      AppLogger.instance.auth(LogLevel.warn, '畅行嘉大：统一认证会话已失效，需要重新登录一卡通');
      throw ChangxingNeedUnifiedAuthException();
    } on TimeoutException catch (e) {
      // 网络不确定（探测 / 网关 / 统一认证暂不可达）：可重试，不算登录过期。
      throw ChangxingCasLoginException(e.message ?? '服务暂时无法连接，请稍后重试');
    } on StateError catch (e) {
      AppLogger.instance.auth(LogLevel.warn, '畅行嘉大：SSO 链路异常 ${e.message}');
      throw ChangxingCasLoginException('畅行嘉大登录未完成，请稍后重试');
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        AppLogger.instance.auth(LogLevel.warn, '畅行嘉大 CAS 登录超时或被取消');
        throw ChangxingCasLoginException('畅行嘉大登录超时，请稍后重试');
      }
      AppLogger.instance.auth(
        LogLevel.error,
        '畅行嘉大 CAS 登录网络异常: ${e.type} ${e.message}',
      );
      throw ChangxingCasLoginException('网络异常：${e.message}');
    } finally {
      budgetTimer.cancel();
      if (!cancelToken.isCancelled) cancelToken.cancel('changxing login done');
    }
  }

  /// 沿 `cas_wap_login` 走 CAS 链路并返回 tokenId；链路落到登录页 / 网关
  /// 登录页时抛 [CasAuthExpiredException]，链路结束却没有 tokenId 返回 null。
  ///
  /// 经 [CasAuthBroker.getResource] 逐跳跟随，命中带 tokenId 的 Location 即停。
  /// WebVPN 下网关对 newca 的代理登录页（`/https/<enc>/cas/login`，共享
  /// 中间层只识别 http 形态）与站点回调（直连形态
  /// `http://zhx...:8443/...?ticket=`）都需要按本次路由改写后续走：
  /// 在这两处停下，分别还原真实 newca 登录入口 / 改写为代理回调地址，
  /// 绝不回退直连。
  Future<String?> _fetchTokenId(
    CasRoute route, {
    required CancelToken cancelToken,
    required DateTime deadline,
  }) async {
    var url = route.url(_casLoginUrl);
    for (var leg = 0; leg < 5; leg++) {
      final response = await CasAuthBroker.getResource(
        url,
        cancelToken: cancelToken,
        deadline: deadline,
        needsLogin: _isLoginBounce,
        stopAtRedirect: (next) =>
            _extractTokenId(normalizeSsoRedirectUrl(next.toString())) != null ||
            (route.isWebVpn && _needsRouteRewrite(next)),
      );

      final status = response.statusCode ?? 0;
      final location = response.headers.value('location') ?? '';
      if (status >= 300 && status < 400 && location.isNotEmpty) {
        final next = response.realUri.resolve(location);
        final normalized = normalizeSsoRedirectUrl('$next');
        final tokenId = _extractTokenId(normalized);
        if (tokenId != null) return tokenId;
        if (route.isWebVpn && _isProxiedCasLogin(next)) {
          url = normalized;
          continue;
        }
        if (route.isWebVpn && _isDirectCasCallback(next)) {
          url = route.url('$next');
          continue;
        }
        return null;
      }

      // 非重定向终点：兜底检查最终 URL 是否带 tokenId。
      return _extractTokenId(
        normalizeSsoRedirectUrl(response.realUri.toString()),
      );
    }
    return null;
  }

  bool _needsRouteRewrite(Uri uri) =>
      _isProxiedCasLogin(uri) || _isDirectCasCallback(uri);

  /// WebVPN 网关代理的统一认证登录页（没有 newca 的 SSO Cookie）。
  bool _isProxiedCasLogin(Uri uri) =>
      uri.host.toLowerCase() == 'webvpn.zjxu.edu.cn' &&
      uri.path.toLowerCase().endsWith('/cas/login');

  /// 站点 CAS 回调（直连形态）：WebVPN 路由下需改写后再请求。
  bool _isDirectCasCallback(Uri uri) =>
      uri.host.toLowerCase() == 'zhx.zjxu.edu.cn' &&
      uri.path.contains('/cas_login_back');

  /// 登录页判定：统一认证登录页 / WebVPN 网关登录页（会话缺失的 bounce）。
  bool _isLoginBounce(Response<List<int>> response) {
    final realUrl = response.realUri.toString();
    if (isZhengfangGatewayLoginUrl(realUrl)) return true;
    final html = utf8.decode(response.data ?? const [], allowMalformed: true);
    return CasAuthBroker.isCasLoginExchange(realUrl: realUrl, html: html) ||
        isUnifiedAuthLoginFormResponse(realUrl, html);
  }

  /// API 请求统一选项：不跟随重定向（登录 bounce 必须可见），2xx/3xx 交由
  /// [_jsonOrBounce] 分类，4xx/5xx 仍按原样抛 [DioException]。
  Options _apiOptions({
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
  /// 抛 [_ApiLoginBounce]，其它非 JSON 响应抛 [ChangxingCasLoginException]。
  Map<String, dynamic> _jsonOrBounce(Response<dynamic> response) {
    final status = response.statusCode ?? 0;
    if (status >= 300 && status < 400) {
      final location = response.headers.value('location') ?? '';
      final resolved = location.isEmpty
          ? ''
          : response.requestOptions.uri.resolve(location).toString();
      if (_isLoginBounceUrl(resolved)) throw const _ApiLoginBounce();
      throw ChangxingCasLoginException('服务返回了意外的重定向，请稍后重试');
    }
    final data = response.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    final realUrl = response.realUri.toString();
    if (isZhengfangGatewayLoginUrl(realUrl) ||
        (data is String &&
            (isUnifiedAuthLoginFormResponse(realUrl, data) ||
                looksLikeUnifiedAuthLoginHtml(data)))) {
      throw const _ApiLoginBounce();
    }
    if (data == null) return <String, dynamic>{};
    throw ChangxingCasLoginException('服务响应异常，请稍后重试');
  }

  /// Location / 最终 URL 是否为统一认证 / 网关登录页。WebVPN 下网关把 newca
  /// 登录页代理成 `/https/<enc>/cas/login`，先 [normalizeSsoRedirectUrl]
  /// 还原再判定（与 [_fetchTokenId] 一致）。
  bool _isLoginBounceUrl(String url) {
    if (url.isEmpty) return false;
    final normalized = normalizeSsoRedirectUrl(url);
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
  Future<Response<dynamic>> _sendApi(
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
              options: _apiOptions(
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
      targetUrl: _casLoginUrl,
    );
    final created = _RouteFlight(owner, revision, future);
    _routeFlight = created;
    return future
        .then((route) {
          if (owner == null || _tokenBinding.isCurrent(owner, revision)) {
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
  Future<CasRoute> _routeForApi(String? owner, int revision) async {
    try {
      return await _routeFor(owner, revision);
    } on CasAuthExpiredException {
      throw ChangxingAuthExpiredException();
    } on TimeoutException catch (e) {
      throw ChangxingCasLoginException(e.message ?? '服务暂时无法连接，请稍后重试');
    }
  }

  Future<ChangxingUserProfile> fetchUserProfile() async {
    final json = await _postJson('/user/getUserDetail', {});
    final code = _extractCode(json);
    if (code != '20000') {
      throw ChangxingCasLoginException(
        _extractMessage(json, fallback: '获取用户信息失败'),
      );
    }
    final body = _extractDataMap(json)['body'] as Map<String, dynamic>? ?? {};
    return ChangxingUserProfile.fromJson(body);
  }

  Future<int> fetchUnreadCount() async {
    final json = await _get('/msg/getNoReadCount');
    final code = _extractCode(json);
    if (code != '20000') return 0;
    final data = _extractDataMap(json);
    final count = data['count'];
    if (count is int) return count;
    return int.tryParse(count?.toString() ?? '') ?? 0;
  }

  Future<List<ChangxingApplication>> fetchApplications({
    int page = 1,
    int pageSize = 20,
    int status = 999,
  }) async {
    final json = await _get(
      '/approvalForm/listPage/bystudent',
      query: {'current': '$page', 'pageSize': '$pageSize', 'status': '$status'},
    );
    final code = _extractCode(json);
    if (code != '20000') {
      throw ChangxingCasLoginException(
        _extractMessage(json, fallback: '获取申请列表失败'),
      );
    }
    final body = _extractDataMap(json)['body'] as Map<String, dynamic>? ?? {};
    final records = (body['records'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(ChangxingApplication.fromJson)
        .toList();
    return records;
  }

  Future<ChangxingApplicationDetail> fetchApplicationDetail(int id) async {
    final json = await _postForm('/approvalForm/getOne', {'id': '$id'});
    _ensureSuccess(json, fallback: '获取申请详情失败');
    final data = _extractDataMap(json)['data'] as Map<String, dynamic>? ?? {};
    return ChangxingApplicationDetail.fromJson(data);
  }

  Future<List<ChangxingAreaNode>> fetchAreaChildren(int parentId) async {
    final json = await _get(
      '/area/getChildArea',
      query: {'parentId': '$parentId'},
    );
    _ensureSuccess(json, fallback: '获取地区信息失败');
    final body =
        _extractDataMap(json)['body'] as List<dynamic>? ?? const <dynamic>[];
    return body
        .whereType<Map<String, dynamic>>()
        .map(ChangxingAreaNode.fromJson)
        .toList();
  }

  Future<List<ChangxingAreaNode>> fetchAreaParents(int areaId) async {
    final json = await _get(
      '/area/getParentArea',
      query: {'areaId': '$areaId'},
    );
    _ensureSuccess(json, fallback: '获取上级地区失败');
    final body =
        _extractDataMap(json)['body'] as List<dynamic>? ?? const <dynamic>[];
    return body
        .whereType<Map<String, dynamic>>()
        .map(ChangxingAreaNode.fromJson)
        .toList();
  }

  Future<bool> fetchFanxiaoEnableFlag() async {
    try {
      final json = await _get(
        '/dict/getDictList',
        query: {'labels': 'SYSTEM_LABEL_fanxiaoEnable', 'pageSize': '10000'},
      );
      final code = _extractCode(json);
      if (code != '20000') return false;
      final body = _extractDataMap(json)['body'] as Map<String, dynamic>? ?? {};
      final records = body['records'] as List<dynamic>? ?? const <dynamic>[];
      if (records.isEmpty) return false;
      final first = records.first as Map<String, dynamic>? ?? {};
      return first['ename']?.toString() == '1';
    } catch (_) {
      return false;
    }
  }

  Future<String?> fetchImageByMd5(String md5) async {
    if (md5.trim().isEmpty) return null;
    final json = await _get('/image/getOne', query: {'md5': md5.trim()});
    _ensureSuccess(json, fallback: '获取附件预览失败');
    final data = _extractDataMap(json)['data'] as Map<String, dynamic>? ?? {};
    final base64 = data['base64']?.toString().trim() ?? '';
    if (base64.isEmpty) return null;
    return 'data:image/png;base64,$base64';
  }

  Future<ChangxingUploadResult> uploadAttachment(
    String filePath,
    String fileName,
  ) async {
    // 调用方发起时的身份：文件准备（`await`）前后、发送之前都必须复核，
    // 绝不把 A 发起的附件以 B 的 token 发出。
    final entryOwner = _tokenBinding.currentOwner;
    final entryRevision = UnifiedAuthService.instance.sessionRevision;
    if (entryOwner == null) {
      throw ChangxingAuthExpiredException();
    }

    void ensureEntryIdentityCurrent() {
      if (_tokenBinding.isCurrent(entryOwner, entryRevision)) return;
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }

    await DioClient.instance.ensureInitialized();
    ensureEntryIdentityCurrent();

    await restoreSession();
    ensureEntryIdentityCurrent();
    if (!_tokenBinding.isBindingCurrent(entryOwner, entryRevision)) {
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }
    if (_tokenBinding.currentToken == null) {
      throw ChangxingAuthExpiredException();
    }

    // 选路（首次 / 过期时会确认 CAS service 并补 WebVPN 网关会话）；
    // 之后再次复核身份，避免 A 发起的附件经 B 的路由 / token 发出。
    final route = await _routeForApi(entryOwner, entryRevision);
    ensureEntryIdentityCurrent();
    if (!_tokenBinding.isBindingCurrent(entryOwner, entryRevision)) {
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }

    final effectiveName = fileName.trim().isEmpty
        ? filePath.split(RegExp(r'[\\/]')).last
        : fileName.trim();
    final multipartFile = await MultipartFile.fromFile(
      filePath,
      filename: effectiveName,
    );

    // 文件准备之后、发送之前：再次复核身份与绑定，并使用复核后的 token。
    ensureEntryIdentityCurrent();
    final token = _tokenBinding.currentToken;
    if (token == null ||
        !_tokenBinding.isBindingCurrent(entryOwner, entryRevision)) {
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }

    final formData = FormData.fromMap({
      'valiFace': 'false',
      'file': multipartFile,
    });

    final response = await _sendApi(
      route,
      Uri.parse(route.url('$_baseUrl/image/add/single')),
      method: 'POST',
      data: formData,
      headers: {'token': token},
    );

    final Map<String, dynamic> json;
    try {
      json = _jsonOrBounce(response);
    } on _ApiLoginBounce {
      _routeLease = null;
      throw ChangxingAuthExpiredException();
    }
    // 迟到结果守卫：等待期间身份 / token 绑定已变化，响应不属于当前会话。
    if (!_tokenBinding.isCurrent(entryOwner, entryRevision) ||
        !_tokenBinding.isBindingCurrent(entryOwner, entryRevision)) {
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }
    final code = _extractCode(json);
    if (code == '500001') {
      await _tokenBinding.clearIfCurrent(entryOwner, entryRevision);
      throw ChangxingAuthExpiredException(
        _extractMessage(json, fallback: '令牌错误，请重新登录'),
      );
    }
    _ensureSuccess(json, fallback: '上传附件失败');
    final data = _extractDataMap(json)['data'] as Map<String, dynamic>? ?? {};
    return ChangxingUploadResult(
      md5: data['md5']?.toString().trim() ?? '',
      base64: data['base64']?.toString().trim() ?? '',
    );
  }

  Future<void> submitLeaveRequest({
    int? id,
    required DateTime startTime,
    required DateTime endTime,
    required String descr,
    required int toAreaCode,
    required String toAddr,
    required String emergencyContact,
    required String emergencyPhone,
    required String userPhone,
    required List<String> trafficTools,
    String img = '',
    String annex = '',
  }) async {
    final request = buildLeaveRequestSubmitRequest(
      id: id,
      startTime: startTime,
      endTime: endTime,
      descr: descr,
      toAreaCode: toAreaCode,
      toAddr: toAddr,
      emergencyContact: emergencyContact,
      emergencyPhone: emergencyPhone,
      userPhone: userPhone,
      trafficTools: trafficTools,
      img: img,
      annex: annex,
    );
    final json = await _postJson(request.path, request.payload);
    _ensureSuccess(json, fallback: id == null ? '提交请假失败' : '修改请假失败');
  }

  Future<void> submitLeaveSchool({
    int? id,
    required DateTime startTime,
    required DateTime endTime,
    required String descr,
    required int toAreaCode,
    required String toAddr,
    required String emergencyContact,
    required String emergencyPhone,
    required String userPhone,
    required List<String> trafficTools,
  }) async {
    final request = buildLeaveSchoolSubmitRequest(
      id: id,
      startTime: startTime,
      endTime: endTime,
      descr: descr,
      toAreaCode: toAreaCode,
      toAddr: toAddr,
      emergencyContact: emergencyContact,
      emergencyPhone: emergencyPhone,
      userPhone: userPhone,
      trafficTools: trafficTools,
    );
    final json = await _postJson(request.path, request.payload);
    _ensureSuccess(json, fallback: id == null ? '提交离校失败' : '修改离校失败');
  }

  Future<void> submitBackSchool({
    int? id,
    required String userPhone,
    required DateTime startTime,
    required String trafficTool,
    required String trafficDetail,
    required String nativePlace,
    required int fromAreaCode,
    required String emergencyContact,
    required String emergencyPhone,
    required int backStatus,
    required String notBackReason,
    String img = '',
    String annex = '',
  }) async {
    final request = buildBackSchoolSubmitRequest(
      id: id,
      userPhone: userPhone,
      startTime: startTime,
      trafficTool: trafficTool,
      trafficDetail: trafficDetail,
      nativePlace: nativePlace,
      fromAreaCode: fromAreaCode,
      emergencyContact: emergencyContact,
      emergencyPhone: emergencyPhone,
      backStatus: backStatus,
      notBackReason: notBackReason,
      img: img,
      annex: annex,
    );
    final json = await _postJson(request.path, request.payload);
    _ensureSuccess(json, fallback: id == null ? '提交返校失败' : '修改返校失败');
  }

  Future<void> submitOvertime({int? id, required String descr}) async {
    final request = buildOvertimeSubmitRequest(id: id, descr: descr);
    final json = await _postJson(request.path, request.payload);
    _ensureSuccess(json, fallback: id == null ? '提交超时失败' : '修改超时失败');
  }

  /// 提交体里的时间统一为本地墙钟 `yyyy-MM-dd HH:mm:ss` 字符串。
  ///
  /// `DateTime` 不能被 `jsonEncode` 直接序列化（会抛 `JsonUnsupportedObjectError`），
  /// 且服务端读到的时间是不带时区的墙钟。格式与服务端返回值（`DateTime.tryParse`
  /// 可解析）同构；尚未对真实服务端做设备端到端验证。
  @visibleForTesting
  static String formatSubmitTime(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    final local = value.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-'
        '${two(local.day)} ${two(local.hour)}:${two(local.minute)}:'
        '${two(local.second)}';
  }

  @visibleForTesting
  static ChangxingSubmitRequest buildLeaveRequestSubmitRequest({
    int? id,
    required DateTime startTime,
    required DateTime endTime,
    required String descr,
    required int toAreaCode,
    required String toAddr,
    required String emergencyContact,
    required String emergencyPhone,
    required String userPhone,
    required List<String> trafficTools,
    String img = '',
    String annex = '',
  }) {
    final payload = <String, dynamic>{
      'startTime': formatSubmitTime(startTime),
      'endTime': formatSubmitTime(endTime),
      'descr': descr,
      'toAreaCode': toAreaCode,
      'toAddr': toAddr,
      'emergencyContact': emergencyContact,
      'emergencyPhone': emergencyPhone,
      'userPhone': userPhone,
      'trafficTool': trafficTools.join(','),
      'img': img,
      'annex': annex,
      'type': 1,
    };
    if (id != null) payload['id'] = id;
    return ChangxingSubmitRequest(
      path: id == null ? '/approvalForm/qingjia/add' : '/approvalForm/edit',
      payload: payload,
    );
  }

  @visibleForTesting
  static ChangxingSubmitRequest buildLeaveSchoolSubmitRequest({
    int? id,
    required DateTime startTime,
    required DateTime endTime,
    required String descr,
    required int toAreaCode,
    required String toAddr,
    required String emergencyContact,
    required String emergencyPhone,
    required String userPhone,
    required List<String> trafficTools,
  }) {
    final payload = <String, dynamic>{
      'startTime': formatSubmitTime(startTime),
      'endTime': formatSubmitTime(endTime),
      'descr': descr,
      'toAreaCode': toAreaCode,
      'toAddr': toAddr,
      'emergencyContact': emergencyContact,
      'emergencyPhone': emergencyPhone,
      'userPhone': userPhone,
      'trafficTool': trafficTools.join(','),
      'type': 2,
    };
    if (id != null) payload['id'] = id;
    return ChangxingSubmitRequest(
      path: id == null ? '/approvalForm/lixiao/add' : '/approvalForm/edit',
      payload: payload,
    );
  }

  @visibleForTesting
  static ChangxingSubmitRequest buildBackSchoolSubmitRequest({
    int? id,
    required String userPhone,
    required DateTime startTime,
    required String trafficTool,
    required String trafficDetail,
    required String nativePlace,
    required int fromAreaCode,
    required String emergencyContact,
    required String emergencyPhone,
    required int backStatus,
    required String notBackReason,
    String img = '',
    String annex = '',
  }) {
    final payload = <String, dynamic>{
      'userPhone': userPhone,
      'startTime': formatSubmitTime(startTime),
      'trafficTool': trafficTool,
      'trafficDetail': trafficDetail,
      'nativePlace': nativePlace,
      'fromAreaCode': fromAreaCode,
      'emergencyContact': emergencyContact,
      'emergencyPhone': emergencyPhone,
      'backStatus': backStatus,
      'notBackReason': notBackReason,
      'img': img,
      'annex': annex,
      'type': 3,
    };
    if (id != null) payload['id'] = id;
    return ChangxingSubmitRequest(
      path: id == null ? '/approvalForm/fanxiao/add' : '/approvalForm/edit',
      payload: payload,
    );
  }

  @visibleForTesting
  static ChangxingSubmitRequest buildOvertimeSubmitRequest({
    int? id,
    required String descr,
  }) {
    final payload = <String, dynamic>{'type': 4, 'descr': descr};
    if (id != null) payload['id'] = id;
    return ChangxingSubmitRequest(
      path: '/approvalForm/overtime/add',
      payload: payload,
    );
  }

  Future<Map<String, dynamic>> _get(
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

  Future<Map<String, dynamic>> _postJson(
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

  Future<Map<String, dynamic>> _postForm(
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
    final entryOwner = _tokenBinding.currentOwner;
    final entryRevision = UnifiedAuthService.instance.sessionRevision;
    final identityCaptured = requiresToken && entryOwner != null;

    void ensureEntryIdentityCurrent() {
      if (!identityCaptured) return;
      if (_tokenBinding.isCurrent(entryOwner, entryRevision)) return;
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }

    if (requiresToken && entryOwner == null) {
      // 没有可验证的调用方身份：与无 token 路径同分类，直接视为会话失效。
      throw ChangxingAuthExpiredException();
    }

    await DioClient.instance.ensureInitialized();
    ensureEntryIdentityCurrent();

    await restoreSession();
    ensureEntryIdentityCurrent();

    final token = _tokenBinding.currentToken;
    if (requiresToken && token == null) {
      // 无 token / token 归属与当前 CAS 身份不一致 / 绑定 revision 已漂移
      // 一律视为没有可用会话（分类保持原样）。
      throw ChangxingAuthExpiredException();
    }
    if (identityCaptured &&
        !_tokenBinding.isBindingCurrent(entryOwner, entryRevision)) {
      // restore 恢复出来的绑定不属于调用方身份（恢复期间换号）。
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }

    // 选路（首次 / 过期时会确认 CAS service 并补 WebVPN 网关会话）；选路
    // 期间身份变化则放弃，绝不把 A 的 payload 经 B 的路由 / token 发出。
    final route = await _routeForApi(entryOwner, entryRevision);
    ensureEntryIdentityCurrent();
    if (identityCaptured &&
        !_tokenBinding.isBindingCurrent(entryOwner, entryRevision)) {
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }

    final uri = Uri.parse(
      route.url(
        Uri.parse('$_baseUrl$path').replace(queryParameters: query).toString(),
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
        !_tokenBinding.isBindingCurrent(entryOwner, entryRevision)) {
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }

    final response = await _sendApi(
      route,
      uri,
      method: method,
      data: data,
      contentType: contentType,
      headers: headers,
    );

    final Map<String, dynamic> json;
    try {
      json = _jsonOrBounce(response);
    } on _ApiLoginBounce {
      // 登录页 bounce：只丢弃选路缓存（下次重建网关会话），不清全局 CAS
      // 会话、不 markLoggedOut。
      _routeLease = null;
      throw ChangxingAuthExpiredException();
    }
    // 迟到结果守卫：等待期间身份 / token 绑定已变化，响应不属于当前会话，
    // 不得把旧身份数据返回给新会话；此后的 500001 也不得清掉新 token。
    if (identityCaptured &&
        (!_tokenBinding.isCurrent(entryOwner, entryRevision) ||
            !_tokenBinding.isBindingCurrent(entryOwner, entryRevision))) {
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }
    final code = _extractCode(json);
    if (code == '500001') {
      if (identityCaptured) {
        await _tokenBinding.clearIfCurrent(entryOwner, entryRevision);
      }
      throw ChangxingAuthExpiredException(
        _extractMessage(json, fallback: '令牌错误，请重新登录'),
      );
    }
    return json;
  }

  String _extractCode(Map<String, dynamic> json) {
    final data = _extractDataMap(json);
    return data['code']?.toString() ?? json['code']?.toString() ?? '';
  }

  void _ensureSuccess(Map<String, dynamic> json, {required String fallback}) {
    final code = _extractCode(json);
    if (code != '20000') {
      throw ChangxingCasLoginException(
        _extractMessage(json, fallback: fallback),
      );
    }
  }

  String _extractMessage(
    Map<String, dynamic> json, {
    required String fallback,
  }) {
    final data = _extractDataMap(json);
    return data['msg']?.toString() ??
        data['errmsg']?.toString() ??
        json['msg']?.toString() ??
        fallback;
  }

  Map<String, dynamic> _extractDataMap(Map<String, dynamic> json) {
    final data = json['data'];
    if (data is Map<String, dynamic>) return data;
    return <String, dynamic>{};
  }

  String? _extractTokenId(String url) {
    final uri = Uri.tryParse(url);
    final tokenId = uri?.queryParameters['tokenId']?.trim() ?? '';
    return tokenId.isEmpty ? null : tokenId;
  }

  @visibleForTesting
  static String normalizeSsoRedirectUrl(String url) {
    final raw = url.trim();
    if (raw.isEmpty) return raw;

    final unwrappedUnifiedAuthUrl = _unwrapProxiedUnifiedAuthLoginUrl(raw);
    if (unwrappedUnifiedAuthUrl != null) {
      return unwrappedUnifiedAuthUrl;
    }

    final uri = Uri.tryParse(raw);
    if (uri == null) return raw;
    final host = uri.host.toLowerCase();
    if (host == 'zhx.zjxu.edu.cn' && uri.path.contains('/cas_login_back')) {
      return ZhengfangAuth.instance.buildWebVpnProxyUrl(raw);
    }
    return raw;
  }

  static String? _unwrapProxiedUnifiedAuthLoginUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.toLowerCase() != 'webvpn.zjxu.edu.cn') {
      return null;
    }

    if (!uri.path.toLowerCase().endsWith('/cas/login')) {
      return null;
    }

    final service = uri.queryParameters['service']?.trim() ?? '';
    if (service.isEmpty) return null;

    return Uri.parse(_unifiedAuthLoginUrl)
        .replace(queryParameters: uri.queryParameters)
        .toString();
  }

  @visibleForTesting
  static bool isUnifiedAuthLoginFormResponse(String url, String html) {
    final normalizedUrl = normalizeSsoRedirectUrl(url);
    return isUnifiedAuthLoginEntryUrl(normalizedUrl) &&
        looksLikeUnifiedAuthLoginHtml(html);
  }

  /// 测试用：以真实落盘格式（owner + token 单条 JSON）构造 envelope。
  @visibleForTesting
  static String encodeTokenEnvelope({
    required String owner,
    required String token,
  }) => ChangxingTokenBinding.encodeEnvelope(owner: owner, token: token);

  /// 测试用：当前内存绑定的 owner（无绑定 / 身份不符时为 null）。
  @visibleForTesting
  String? get debugBoundOwner => _tokenBinding.debugBoundOwner;

  /// 测试用：当前内存绑定对应的 `sessionRevision`（供断言同账号重登）。
  @visibleForTesting
  int? get debugBoundRevision => _tokenBinding.debugBoundRevision;

  @visibleForTesting
  void debugReset() {
    _routeLease = null;
    _routeFlight = null;
    _tokenBinding.debugReset();
  }
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

/// API 响应命中统一认证 / WebVPN 网关登录页（会话或网关 Cookie 缺失）。
class _ApiLoginBounce implements Exception {
  const _ApiLoginBounce();
}
