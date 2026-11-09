import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/network/dio_client.dart';

/// 第二课堂专用认证结果。
///
/// 不复用 [UnifiedAuthService.validateSession]：它把 CAS 登录页视为全局
/// 会话失效并可能清 CAS Cookie；第二课堂只关心自己的 `SESSION`，失败时
/// 不得撤销统一认证身份。
enum SecondClassroomAuthState {
  /// 已建立第二课堂 `SESSION`，且服务端返回的 userId 与当前统一认证账号一致。
  authenticated,

  /// 统一认证未登录，或第二课堂 ticket 未被消费；需要用户显式登录。
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

/// 第二课堂 CAS 会话管理。
///
/// 认证链路（2026-11-09 实测）：
/// 1. 用统一认证 Cookie 请求
///    `https://newca.zjxu.edu.cn/cas/login?service=https://twdekt.zjxu.edu.cn/dekt/`；
/// 2. CAS 返回 302 到 `https://twdekt.zjxu.edu.cn/dekt/?ticket=ST-...`；
/// 3. 跟随该 302，第二课堂在 `/dekt/` 消费 ticket 并下发 host-only
///    `SESSION`（Path=/dekt）；
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
  static const _twdektOrigin = 'https://twdekt.zjxu.edu.cn';
  static const _menuToken = 'c3lzLmluZGV4Lm0=';
  static const _validationFreshness = Duration(minutes: 2);

  final Dio? _injectedDio;
  final CookieJar? _injectedCookieJar;
  final SecondClassroomAccountProvider _accountProvider;
  final SecondClassroomCasLoggedInProvider _casLoggedInProvider;

  bool _authenticated = false;
  String? _userId;
  DateTime? _validatedAt;
  String? _lastAccount;
  bool _lastLoggedIn = false;
  Future<void>? _pendingClear;

  /// 最近一次已验证的第二个课堂身份；超过 2 分钟或账号变化即不再可信。
  bool get isAuthenticated {
    final account = _accountProvider()?.trim();
    final validatedAt = _validatedAt;
    return _authenticated &&
        account != null &&
        account.isNotEmpty &&
        _userId == account &&
        validatedAt != null &&
        DateTime.now().difference(validatedAt) < _validationFreshness;
  }

  /// 仅用于诊断，不要展示或写日志。
  String? get currentUserId => isAuthenticated ? _userId : null;

  static String? _defaultAccountProvider() =>
      UnifiedAuthService.instance.verifiedAccount;

  static bool _defaultCasLoggedInProvider() =>
      UnifiedAuthService.instance.isLoggedIn;

  /// 确保第二课堂会话可用。不会提交账号密码，也不会修改统一认证身份。
  Future<SecondClassroomAuthState> ensureSession({bool force = false}) async {
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

    if (!force && isAuthenticated) {
      return SecondClassroomAuthState.authenticated;
    }

    try {
      final casUri = _buildCasLoginUri();
      final casResponse = await _dio.getUri<String>(
        casUri,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
          headers: {'Referer': casUri.toString()},
        ),
      );

      final status = casResponse.statusCode ?? 0;
      final location = casResponse.headers.value('location') ?? '';
      final html = casResponse.data ?? '';

      if (status >= 200 && status < 300) {
        if (looksLikeUnifiedAuthLoginHtml(html)) {
          return SecondClassroomAuthState.needsLogin;
        }
        return SecondClassroomAuthState.failed;
      }
      if (status >= 500) {
        return SecondClassroomAuthState.unavailable;
      }

      if (status != 301 && status != 302 && status != 303 && status != 307) {
        return SecondClassroomAuthState.failed;
      }

      final locationUri = casUri.resolve(location);
      if (isUnifiedAuthLoginEntryUrl(locationUri.toString()) &&
          !urlHasCasTicket(locationUri.toString())) {
        return SecondClassroomAuthState.needsLogin;
      }
      if (!_isSecondClassroomUri(locationUri)) {
        AppLogger.instance.auth(LogLevel.warn, '第二课堂 CAS 跳转目标不在 twdekt，拒绝跟随');
        return SecondClassroomAuthState.failed;
      }

      await _followTicketRedirects(locationUri);
      return await _probe(account);
    } on DioException catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '第二课堂 CAS 会话建立网络异常: ${error.type} ${error.message}',
        error: error,
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

  /// 只清第二课堂 host-only Cookie；绝不触碰统一认证 / 正方 CookieJar。
  Future<void> clearSession() async {
    _authenticated = false;
    _userId = null;
    _validatedAt = null;
    try {
      if (_injectedDio == null) {
        await DioClient.instance.ensureInitialized();
      }
      await _cookieJar.delete(Uri.parse(serviceUrl));
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
    _authenticated = false;
    _userId = null;
    _validatedAt = null;
  }

  Dio get _dio => _injectedDio ?? DioClient.instance.unifiedAuthDio;

  CookieJar get _cookieJar =>
      _injectedCookieJar ?? DioClient.instance.unifiedAuthCookieJar;

  Uri _buildCasLoginUri() {
    return Uri.parse('$_newcaOrigin/cas/login')
        .replace(queryParameters: {'service': serviceUrl});
  }

  bool _isSecondClassroomUri(Uri uri) {
    return uri.scheme == 'https' &&
        uri.host.toLowerCase() == 'twdekt.zjxu.edu.cn';
  }

  Future<void> _followTicketRedirects(Uri start) async {
    var current = start;
    for (var hop = 0; hop < 6; hop++) {
      final response = await _dio.getUri<String>(
        current,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
          headers: {'Referer': serviceUrl},
        ),
      );
      final next = response.headers.value('location') ?? '';
      if (next.isEmpty) return;
      final resolved = current.resolve(next);
      if (!_isSecondClassroomUri(resolved)) {
        AppLogger.instance.auth(
          LogLevel.warn,
          '第二课堂 ticket 链跳到非 twdekt 目标，停止跟随',
        );
        return;
      }
      current = resolved;
    }
  }

  Future<SecondClassroomAuthState> _probe(String account) async {
    final uri = Uri.parse('$_twdektOrigin/dekt/mobile/index');
    try {
      final response = await _dio.postUri<Object?>(
        uri,
        data: {'.me': _menuToken},
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.json,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
          headers: const {
            'Accept': 'application/json, text/plain, */*',
            'Origin': _twdektOrigin,
            'Referer': '$_twdektOrigin/dekt/wx/index?_WXFTL=0',
            'X-Requested-With': 'XMLHttpRequest',
          },
        ),
      );

      final status = response.statusCode ?? 0;
      if (status >= 500) {
        return SecondClassroomAuthState.unavailable;
      }
      if (status < 200 || status >= 300) {
        return SecondClassroomAuthState.failed;
      }

      final payload = _asMap(response.data);
      if (payload == null) {
        return SecondClassroomAuthState.failed;
      }
      final extend = _asMap(payload['extend']);
      final login = extend?['login'] == true;
      final userId = extend?['userId']?.toString().trim() ?? '';
      final userSource = extend?['userSource']?.toString().trim() ?? '';

      if (!login || userId.isEmpty) {
        await clearSession();
        return SecondClassroomAuthState.needsLogin;
      }
      if (userId != account) {
        await clearSession();
        AppLogger.instance.auth(
          LogLevel.warn,
          '第二课堂会话身份与统一认证账号不一致，已清除第二课堂 Cookie',
        );
        return SecondClassroomAuthState.identityMismatch;
      }

      _authenticated = true;
      _userId = userId;
      _validatedAt = DateTime.now();
      AppLogger.instance.auth(
        LogLevel.info,
        '第二课堂 CAS 会话已建立: userSource=${userSource.isEmpty ? 'unknown' : userSource}',
      );
      return SecondClassroomAuthState.authenticated;
    } on DioException catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '第二课堂会话探测网络异常: ${error.type} ${error.message}',
        error: error,
        stackTrace: stackTrace,
      );
      return SecondClassroomAuthState.unavailable;
    } on FormatException catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '第二课堂会话探测响应格式异常',
        error: error,
        stackTrace: stackTrace,
      );
      return SecondClassroomAuthState.failed;
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
