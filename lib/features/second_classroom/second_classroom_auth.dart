import 'dart:async';
import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/cas_routed_access.dart';
import '../../core/auth/login_page_detection.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/network/dio_client.dart';
import 'second_classroom_route.dart';

/// 第二课堂专用认证结果。
///
/// 不复用 [UnifiedAuthService.validateSession]：它把 CAS 登录页视为全局
/// 会话失效并可能清 CAS Cookie；第二课堂只关心自己的 `SESSION`，失败时
/// 不得撤销统一认证身份。
enum SecondClassroomAuthState {
  /// 已建立第二课堂 `SESSION`，且服务端返回的 userId 与当前统一认证账号一致。
  authenticated,

  /// 明确命中统一认证 / WebVPN 登录页，或第二课堂探测返回未登录。
  needsLogin,

  /// 第二课堂返回了另一个学生的身份，已清除第二课堂 Cookie，按失败处理。
  identityMismatch,

  /// 协议异常（ticket 未消费、响应结构不认识等），不撤销统一认证。
  failed,

  /// 网络异常 / 5xx，无法下结论；保留现有 Cookie。
  unavailable,
}

typedef SecondClassroomAccountProvider = String? Function();
typedef SecondClassroomCasLoggedInProvider = bool Function();

typedef _TicketResult = ({
  SecondClassroomRoute route,
  SecondClassroomAuthState? failure,
});

typedef _ProbeResult = ({SecondClassroomAuthState? state, bool gatewayBounce});

/// 第二课堂 CAS 会话管理。
///
/// 认证链路（2026-11-09 实测）：
/// 1. 用统一认证 Cookie 请求
///    `https://newca.zjxu.edu.cn/cas/login?service=https://twdekt.zjxu.edu.cn/dekt/`；
/// 2. CAS 返回 302 到 `https://twdekt.zjxu.edu.cn/dekt/?ticket=ST-...`；
/// 3. 跟随该 302，第二课堂在 `/dekt/` 消费 ticket 并下发 host-only
///    `SESSION`（校外可能先跳到第二课堂的 WebVPN 包装）；
/// 4. `POST /dekt/mobile/index` 必须返回 `login:true` 且 `userId` 等于当前
///    统一认证账号。
///
/// 关键边界：CAS service 必须是 `/dekt/`，不能是 `/dekt/wx/index`。后者 CAS
/// 会签发 ticket，但第二课堂不消费，`/mobile/index` 仍是游客。
class SecondClassroomAuth {
  SecondClassroomAuth({
    Dio? dio,
    CookieJar? cookieJar,
    SecondClassroomAccountProvider? accountProvider,
    SecondClassroomCasLoggedInProvider? casLoggedInProvider,
    bool bindAuthListener = true,
  }) : _injectedDio = dio,
       _injectedCookieJar = cookieJar,
       _accountProvider = accountProvider ?? _defaultAccountProvider,
       _casLoggedInProvider =
           casLoggedInProvider ?? _defaultCasLoggedInProvider {
    _lastAccount = _accountProvider();
    _lastLoggedIn = _casLoggedInProvider();
    if (bindAuthListener) {
      UnifiedAuthService.instance.addListener(_onAuthChanged);
    }
  }

  static final SecondClassroomAuth instance = SecondClassroomAuth();

  static String get serviceUrl => CasService.secondClassroom.serviceUrl;
  static const _newcaOrigin = 'https://newca.zjxu.edu.cn';
  static const _menuToken = 'c3lzLmluZGV4Lm0=';
  static const _validationFreshness = Duration(minutes: 2);

  final Dio? _injectedDio;
  final CookieJar? _injectedCookieJar;
  final SecondClassroomAccountProvider _accountProvider;
  final SecondClassroomCasLoggedInProvider _casLoggedInProvider;

  bool _authenticated = false;
  String? _userId;
  DateTime? _validatedAt;
  SecondClassroomRoute? _validatedRoute;
  int? _validatedRevision;
  String? _lastAccount;
  bool _lastLoggedIn = false;
  Future<void>? _pendingClear;

  /// 最近一次已验证的第二课堂身份，绑定统一认证的账号和会话版本，有效期 2 分钟。
  bool get isAuthenticated {
    final account = _accountProvider()?.trim();
    final validatedAt = _validatedAt;
    return _authenticated &&
        account != null &&
        account.isNotEmpty &&
        _userId == account &&
        (_injectedDio != null ||
            _validatedRevision ==
                UnifiedAuthService.instance.sessionRevision) &&
        validatedAt != null &&
        DateTime.now().difference(validatedAt) < _validationFreshness;
  }

  /// 已验证的身份，用于检查请求归属，不展示或写日志。
  String? get currentUserId => isAuthenticated ? _userId : null;

  /// URL 和 Cookie 必须沿用实际通过身份探测的路线。
  SecondClassroomRoute? get authenticatedRoute =>
      isAuthenticated ? _validatedRoute : null;

  static String? _defaultAccountProvider() =>
      UnifiedAuthService.instance.verifiedAccount;

  static bool _defaultCasLoggedInProvider() =>
      UnifiedAuthService.instance.isLoggedIn;

  /// 确保第二课堂会话可用。不会提交账号密码，也不会修改统一认证身份。
  Future<SecondClassroomAuthState> ensureSession({
    bool force = false,
    bool forceWebVpn = false,
  }) async {
    final pendingClear = _pendingClear;
    if (pendingClear != null) {
      await pendingClear;
      if (identical(_pendingClear, pendingClear)) {
        _pendingClear = null;
      }
    }
    if (_injectedDio == null) {
      await DioClient.instance.ensureInitialized();
    }

    if (!_casLoggedInProvider() && _injectedDio == null) {
      await UnifiedAuthService.instance.restoreSession(
        syncWebViewCookies: false,
      );
    }

    final account = _accountProvider()?.trim();
    if (!_casLoggedInProvider() || account == null || account.isEmpty) {
      if (_authenticated || _userId != null) {
        await clearSession();
      }
      return SecondClassroomAuthState.needsLogin;
    }

    if (!force &&
        isAuthenticated &&
        (!forceWebVpn || _validatedRoute == SecondClassroomRoute.webVpn)) {
      return SecondClassroomAuthState.authenticated;
    }

    _resetValidation();
    final auth = UnifiedAuthService.instance;
    final revision = auth.sessionRevision;
    bool isCurrent() =>
        _casLoggedInProvider() &&
        _accountProvider()?.trim() == account &&
        (_injectedDio != null || auth.sessionRevision == revision);

    try {
      var route = forceWebVpn
          ? SecondClassroomRoute.webVpn
          : SecondClassroomRoute.direct;
      var gatewayRetried = false;
      for (var attempt = 0; attempt < 3; attempt++) {
        final ticket = await _exchangeTicket(route, isCurrent);
        if (!isCurrent()) return SecondClassroomAuthState.unavailable;
        route = ticket.route;
        final failure = ticket.failure;

        if (failure != null) {
          if (failure != SecondClassroomAuthState.needsLogin ||
              route != SecondClassroomRoute.webVpn ||
              gatewayRetried) {
            return failure;
          }
        } else {
          final probe = await _probe(account, route, isCurrent);
          final state = probe.state;
          if (state == null) {
            // 直连探测已改道。旧 ticket 可能已在直连消费，代理侧重新签票。
            route = SecondClassroomRoute.webVpn;
            continue;
          }
          if (state == SecondClassroomAuthState.authenticated) {
            if (!isCurrent()) return SecondClassroomAuthState.unavailable;
            _authenticated = true;
            _userId = account;
            _validatedAt = DateTime.now();
            _validatedRoute = route;
            _validatedRevision = revision;
          }
          if (!probe.gatewayBounce || gatewayRetried) return state;
          route = SecondClassroomRoute.webVpn;
        }

        // 已观测到 WebVPN 登录 bounce。沿用 CAS Cookie 预热网关一次，随后
        // 重新签发业务 ticket，避免重放可能已消费的原 ticket。
        gatewayRetried = true;
        if (!isCurrent()) return SecondClassroomAuthState.unavailable;
        await CasAuthBroker.getResource(
          CasService.webVpnGateway.serviceUrl,
          dio: _injectedDio,
          needsLogin: webVpnGatewayResponseNeedsLogin,
        );
        if (!isCurrent()) return SecondClassroomAuthState.unavailable;
      }
      return SecondClassroomAuthState.unavailable;
    } on CasAuthExpiredException {
      return SecondClassroomAuthState.needsLogin;
    } on StateError {
      return SecondClassroomAuthState.unavailable;
    } on TimeoutException {
      return SecondClassroomAuthState.unavailable;
    } on DioException catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '第二课堂 CAS 会话建立网络异常: ${describeGatewayDioFailure(error)}',
        stackTrace: stackTrace,
      );
      return SecondClassroomAuthState.unavailable;
    } on FormatException catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '第二课堂 CAS 响应格式异常',
        error: error,
        stackTrace: stackTrace,
      );
      return SecondClassroomAuthState.failed;
    }
  }

  /// 清直连业务 Cookie 和第二课堂路径下的代理 SESSION，保留共享网关 Cookie。
  Future<void> clearSession() async {
    _resetValidation();
    try {
      if (_injectedDio == null) {
        await DioClient.instance.ensureInitialized();
      }
      await _cookieJar.delete(Uri.parse(serviceUrl));
      final proxyUri = SecondClassroomRoute.webVpn.uriFor(
        SecondClassroomRoute.mobileUri('index'),
      );
      final cookies = await _cookieJar.loadForRequest(proxyUri);
      final expired = <Cookie>[
        for (final cookie in cookies)
          if (cookie.name == 'SESSION' &&
              SecondClassroomRoute.isScopedWebVpnCookiePath(cookie.path ?? ''))
            Cookie(cookie.name, '')
              ..domain = cookie.domain
              ..path = cookie.path
              ..maxAge = 0,
      ];
      if (expired.isNotEmpty) {
        await _cookieJar.saveFromResponse(proxyUri, expired);
      }
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '第二课堂会话清理失败: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @visibleForTesting
  void debugDetach() {
    UnifiedAuthService.instance.removeListener(_onAuthChanged);
    _resetValidation();
  }

  void _resetValidation() {
    _authenticated = false;
    _userId = null;
    _validatedAt = null;
    _validatedRoute = null;
    _validatedRevision = null;
  }

  Dio get _dio => _injectedDio ?? DioClient.instance.unifiedAuthDio;

  CookieJar get _cookieJar =>
      _injectedCookieJar ?? DioClient.instance.unifiedAuthCookieJar;

  Uri _buildCasLoginUri() {
    return Uri.parse('$_newcaOrigin/cas/login')
        .replace(queryParameters: {'service': serviceUrl});
  }

  Future<_TicketResult> _exchangeTicket(
    SecondClassroomRoute route,
    bool Function() isCurrent,
  ) async {
    final casUri = _buildCasLoginUri();
    final response = await _get(casUri, casUri.toString());
    final status = response.statusCode ?? 0;
    if (status >= 500 || !isCurrent()) {
      return (route: route, failure: SecondClassroomAuthState.unavailable);
    }
    final redirect = SecondClassroomRoute.redirectTarget(response);
    // 本次请求本身就发往 CAS 登录 URL，只有正文或重定向能证明未登录。
    if ((redirect != null && SecondClassroomRoute.isLoginUrl(redirect)) ||
        (status >= 200 &&
            status < 300 &&
            looksLikeUnifiedAuthLoginHtml(response.data ?? ''))) {
      return (route: route, failure: SecondClassroomAuthState.needsLogin);
    }
    final redirectRoute = redirect == null
        ? null
        : SecondClassroomRoute.forUri(redirect);
    if (redirect == null || redirectRoute == null) {
      return (route: route, failure: SecondClassroomAuthState.failed);
    }
    final firstHop = redirectRoute == SecondClassroomRoute.direct
        ? route.uriFor(redirect)
        : redirect;
    return _followTicketRedirects(
      firstHop,
      redirectRoute == SecondClassroomRoute.webVpn ? redirectRoute : route,
      isCurrent,
    );
  }

  Future<Response<String>> _get(Uri uri, String referer) => _dio.getUri<String>(
    uri,
    options: Options(
      responseType: ResponseType.plain,
      followRedirects: false,
      validateStatus: (status) => status != null,
      headers: {'Referer': referer},
    ),
  );

  Future<_TicketResult> _followTicketRedirects(
    Uri start,
    SecondClassroomRoute startRoute,
    bool Function() isCurrent,
  ) async {
    var current = start;
    var route = startRoute;
    for (var hop = 0; hop < 6; hop++) {
      final response = await _get(
        current,
        route.uriFor(Uri.parse(serviceUrl)).toString(),
      );
      final status = response.statusCode ?? 0;
      if (status >= 500 || !isCurrent()) {
        return (route: route, failure: SecondClassroomAuthState.unavailable);
      }
      final next = SecondClassroomRoute.redirectTarget(response);
      if (SecondClassroomRoute.isLoginResponse(response, next)) {
        final target = next?.toString();
        return (
          route: target != null && isWebVpnPortalUrl(target)
              ? SecondClassroomRoute.webVpn
              : route,
          failure: SecondClassroomAuthState.needsLogin,
        );
      }
      if (status >= 200 && status < 300) return (route: route, failure: null);
      final nextRoute = next == null ? null : SecondClassroomRoute.forUri(next);
      if (next == null || nextRoute == null) {
        AppLogger.instance.auth(LogLevel.warn, '第二课堂 ticket 跳转无有效业务目标，停止跟随');
        return (route: route, failure: SecondClassroomAuthState.failed);
      }
      current = next;
      route = nextRoute;
    }
    return (route: route, failure: SecondClassroomAuthState.unavailable);
  }

  Future<_ProbeResult> _probe(
    String account,
    SecondClassroomRoute route,
    bool Function() isCurrent,
  ) async {
    final uri = route.uriFor(SecondClassroomRoute.mobileUri('index'));
    try {
      final response = await _dio.postUri<Object?>(
        uri,
        data: {'.me': _menuToken},
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.json,
          followRedirects: false,
          validateStatus: (status) => status != null,
          headers: route.xhrHeaders(uri),
        ),
      );

      final status = response.statusCode ?? 0;
      if (status >= 500 || !isCurrent()) {
        return (
          state: SecondClassroomAuthState.unavailable,
          gatewayBounce: false,
        );
      }
      final redirect = SecondClassroomRoute.redirectTarget(response);
      if (SecondClassroomRoute.isLoginResponse(response, redirect)) {
        return (
          state: SecondClassroomAuthState.needsLogin,
          gatewayBounce:
              route == SecondClassroomRoute.webVpn ||
              (redirect != null && isWebVpnPortalUrl(redirect.toString())),
        );
      }
      if (route == SecondClassroomRoute.direct &&
          redirect != null &&
          SecondClassroomRoute.forUri(redirect) ==
              SecondClassroomRoute.webVpn) {
        return (state: null, gatewayBounce: false);
      }
      if (status < 200 || status >= 300) {
        return (state: SecondClassroomAuthState.failed, gatewayBounce: false);
      }

      final payload = _asMap(response.data);
      if (payload == null) {
        return (state: SecondClassroomAuthState.failed, gatewayBounce: false);
      }
      final extend = _asMap(payload['extend']);
      final login = extend?['login'] == true;
      final userId = extend?['userId']?.toString().trim() ?? '';
      final userSource = extend?['userSource']?.toString().trim() ?? '';

      if (!login || userId.isEmpty) {
        await clearSession();
        return (
          state: SecondClassroomAuthState.needsLogin,
          gatewayBounce: false,
        );
      }
      if (userId != account) {
        await clearSession();
        AppLogger.instance.auth(
          LogLevel.warn,
          '第二课堂会话身份与统一认证账号不一致，已清除第二课堂 Cookie',
        );
        return (
          state: SecondClassroomAuthState.identityMismatch,
          gatewayBounce: false,
        );
      }

      AppLogger.instance.auth(
        LogLevel.info,
        '第二课堂 CAS 会话已建立: userSource=${userSource.isEmpty ? 'unknown' : userSource}',
      );
      return (
        state: SecondClassroomAuthState.authenticated,
        gatewayBounce: false,
      );
    } on DioException catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '第二课堂会话探测网络异常: ${describeGatewayDioFailure(error)}',
        stackTrace: stackTrace,
      );
      return (
        state: SecondClassroomAuthState.unavailable,
        gatewayBounce: false,
      );
    } on FormatException catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '第二课堂会话探测响应格式异常',
        error: error,
        stackTrace: stackTrace,
      );
      return (state: SecondClassroomAuthState.failed, gatewayBounce: false);
    }
  }

  Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is String && value.trim().isNotEmpty) {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
    return null;
  }

  void _onAuthChanged() {
    final account = _accountProvider()?.trim();
    final loggedIn = _casLoggedInProvider();
    final identityChanged = _lastAccount != null && account != _lastAccount;
    final loggedOut = _lastLoggedIn && !loggedIn;
    _lastAccount = account;
    _lastLoggedIn = loggedIn;
    if (identityChanged || loggedOut) {
      _pendingClear = clearSession();
    }
  }
}
