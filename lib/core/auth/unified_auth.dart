import 'dart:async';
import 'dart:io' as io;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../crypto/auth_crypto.dart';
import '../logging/app_logger.dart';
import '../network/cookie_interceptor.dart';
import '../network/dio_client.dart';
import '../network/network_settings.dart';
import '../network/proxy_mode.dart';
import 'auth_failure.dart';
import 'auth_operation_coordinator.dart';
import 'auth_recovery_state_store.dart';
import 'auth_session_persistence.dart';
import 'captcha_challenge.dart';
import 'credential_store.dart';
import 'isolated_auth_session.dart';

part 'unified_auth_challenge.dart';

bool isUnifiedAuthLoginEntryUrl(String currentUrl) {
  final raw = currentUrl.trim();
  if (raw.isEmpty) return false;

  final uri = Uri.tryParse(raw);
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  final path = uri.path.toLowerCase();
  if (host.isEmpty) return path.contains('/cas/login');
  if (host != 'newca.zjxu.edu.cn') return false;
  return path.contains('/cas/login');
}

bool urlHasCasTicket(String location) {
  if (location.isEmpty) return false;
  final uri = Uri.tryParse(location);
  if (uri == null) return false;
  final ticket = uri.queryParameters['ticket'] ?? '';
  if (ticket.isEmpty) return false;
  return ticket.startsWith('ST-');
}

bool isUnifiedAuthAuthenticatedUrl(String currentUrl) {
  final raw = currentUrl.trim();
  if (raw.isEmpty) return false;

  final uri = Uri.tryParse(raw);
  if (uri == null) return false;
  if (isUnifiedAuthLoginEntryUrl(currentUrl)) return false;

  final host = uri.host.toLowerCase();
  final path = uri.path.toLowerCase();
  if (host.isEmpty) {
    return path.contains('/casclient/login');
  }
  if (host == 'newca.zjxu.edu.cn') {
    return path.contains('/casclient/login');
  }
  return host == 'mobilehall.zjxu.edu.cn' ||
      host == 'app.xiaoyuan.ccb.com' ||
      host == 'libapp.zjxu.edu.cn';
}

String? extractUnifiedAuthServiceUrl(String currentUrl) {
  final raw = currentUrl.trim();
  if (raw.isEmpty) return null;

  final uri = Uri.tryParse(raw);
  if (uri == null || !isUnifiedAuthLoginEntryUrl(raw)) return null;

  final serviceUrl = uri.queryParameters['service']?.trim();
  if (serviceUrl == null || serviceUrl.isEmpty) return null;
  return serviceUrl;
}

bool looksLikeUnifiedAuthLoginHtml(String html) {
  final normalizedHtml = html.toLowerCase();
  if (normalizedHtml.isEmpty) return false;
  return normalizedHtml.contains('id="fm1"') ||
      normalizedHtml.contains("id='fm1'") ||
      normalizedHtml.contains('name="execution"') ||
      normalizedHtml.contains("name='execution'") ||
      normalizedHtml.contains('name="lt"') ||
      normalizedHtml.contains("name='lt'") ||
      normalizedHtml.contains('/cas/captcha.html') ||
      normalizedHtml.contains('统一身份认证');
}

sealed class UnifiedAuthLoginResult {
  const UnifiedAuthLoginResult();
}

class UnifiedAuthLoginSuccess extends UnifiedAuthLoginResult {
  const UnifiedAuthLoginSuccess({this.receipt});

  /// 自动恢复路径下**真实**提交产出的 typed receipt；人工登录或已有可信
  /// cookie 短路成功均为 null（短路绝不在自动路径伪造提交）。
  final SessionCommitResult? receipt;
}

class UnifiedAuthLoginFailure extends UnifiedAuthLoginResult {
  UnifiedAuthLoginFailure(this.message, {this.kind = AuthFailureKind.unknown});

  final String message;

  /// 失败分类；默认 [AuthFailureKind.unknown]，不得被当作密码错误或自动重试。
  final AuthFailureKind kind;
}

class UnifiedAuthCaptchaException implements Exception {
  UnifiedAuthCaptchaException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UnifiedAuthIncompleteSessionException implements Exception {
  UnifiedAuthIncompleteSessionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _UnifiedAuthLoginContext {
  const _UnifiedAuthLoginContext({
    required this.serviceUrl,
    required this.lt,
    required this.execution,
    required this.actionUri,
  });

  final String serviceUrl;
  final String lt;
  final String execution;
  final Uri actionUri;
}

/// 验证码事务私有快照：绑定**独立网络会话**（isolated jar/dio）与表单字段，
/// 提交时只使用这一份，禁止重新初始化。
class _UnifiedAuthChallengeContext {
  const _UnifiedAuthChallengeContext({
    required this.serviceUrl,
    required this.lt,
    required this.execution,
    required this.actionUri,
    required this.session,
    required this.expectedEpoch,
  });

  final String serviceUrl;
  final String lt;
  final String execution;
  final Uri actionUri;
  final IsolatedAuthSession session;

  /// prepare 时捕获的持久会话 epoch；提交必须使用它做条件提交，
  /// **不得**在提交时重新读取当前 epoch（否则跨 isolate 撤销会被绕过）。
  final int expectedEpoch;
}

class UnifiedAuthService extends ChangeNotifier {
  UnifiedAuthService._();
  static final UnifiedAuthService instance = UnifiedAuthService._();

  static const defaultServiceUrl =
      'https://newca.zjxu.edu.cn/casClient/login/ydd';

  static const _newcaOrigin = 'https://newca.zjxu.edu.cn';
  static const _serviceHallOrigin = 'https://mobilehall.zjxu.edu.cn';
  static const _paymentOrigin = 'https://app.xiaoyuan.ccb.com';
  static const _libraryOrigin = 'https://libapp.zjxu.edu.cn';
  static const _requestTimeout = Duration(seconds: 12);

  CookieManager? _cookieManager;

  Dio get _dio => DioClient.instance.unifiedAuthDio;
  PersistCookieJar get _cookieJar => DioClient.instance.unifiedAuthCookieJar;

  bool _sessionActive = false;
  String? currentAccount;

  /// 身份修订号：login/logout 时递增，供 restore/validate 丢弃过期结果。
  int _sessionRevision = 0;

  /// 对外只读身份修订号，供其他模块（如私人缓存、自动恢复）判定账号/epoch
  /// 是否变化；只增不减，不改变 [notifyListeners] 契约。
  int get sessionRevision => _sessionRevision;

  final CaptchaChallengeStore<_UnifiedAuthChallengeContext> _captchaChallenges =
      CaptchaChallengeStore<_UnifiedAuthChallengeContext>();

  void _touchSessionRevision() => _sessionRevision++;

  /// 供 part 扩展在登录提交成功后触发通知（extension 不能直接调用
  /// protected 的 [notifyListeners]）。
  void _notifyLoginSuccess() => notifyListeners();

  /// 同状态不 bump；空白账号不得写成已登录。
  void _applySessionIdentity({required bool active, String? account}) {
    final trimmed = account?.trim();
    final nextActive = active && trimmed != null && trimmed.isNotEmpty;
    final nextAccount = nextActive ? trimmed : null;
    if (_sessionActive == nextActive && currentAccount == nextAccount) return;
    _touchSessionRevision();
    _sessionActive = nextActive;
    currentAccount = nextAccount;
    // 身份变化：已备好的验证码事务立即失效（单次提交 + 旧 revision 丢弃）。
    _captchaChallenges.invalidate();
  }

  Future<void>? _cookieSyncFuture;
  final Map<String, Future<bool?>> _sessionValidationFutures = {};
  final Map<String, bool> _sessionValidationSyncWebViewCookies = {};

  bool get isLoggedIn {
    final account = currentAccount?.trim();
    return _sessionActive && account != null && account.isNotEmpty;
  }

  Future<bool> prepareLogin({
    String serviceUrl = defaultServiceUrl,
    CancelToken? cancelToken,
  }) async {
    if (!isLoggedIn) {
      await restoreSession(syncWebViewCookies: false);
    }
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    if (isLoggedIn) return true;
    try {
      final context = await _refreshLoginContext(
        serviceUrl,
        cancelToken: cancelToken,
      );
      return isLoggedIn && context.lt.isEmpty && context.execution.isEmpty;
    } on UnifiedAuthIncompleteSessionException catch (error) {
      AppLogger.instance.auth(LogLevel.warn, error.message);
      return false;
    }
  }

  Future<bool?> validateSession({
    String serviceUrl = defaultServiceUrl,
    bool syncWebViewCookies = true,
  }) {
    if (!isLoggedIn) return Future.value(false);

    final validationKey = '$serviceUrl#$_sessionRevision';
    final existing = _sessionValidationFutures[validationKey];
    if (existing != null) {
      _sessionValidationSyncWebViewCookies[validationKey] =
          (_sessionValidationSyncWebViewCookies[validationKey] ?? false) |
          syncWebViewCookies;
      return existing;
    }

    _sessionValidationSyncWebViewCookies[validationKey] = syncWebViewCookies;
    final future = _validateSessionInner(serviceUrl: serviceUrl);
    _sessionValidationFutures[validationKey] = future;
    return future.whenComplete(() {
      if (identical(_sessionValidationFutures[validationKey], future)) {
        _sessionValidationFutures.remove(validationKey);
        _sessionValidationSyncWebViewCookies.remove(validationKey);
      }
    });
  }

  /// 登出清理失败不影响调用方的失效结论。
  Future<void> _markLoggedOutBestEffort() async {
    try {
      await markLoggedOut();
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '统一认证登出清理失败（不影响失效判定）',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<bool?> _validateSessionInner({required String serviceUrl}) async {
    final revisionAtStart = _sessionRevision;
    try {
      final validator = debugSessionValidator;
      if (validator != null) {
        final result = await validator(serviceUrl);
        if (revisionAtStart != _sessionRevision) return null;
        if (result == false) {
          await _markLoggedOutBestEffort();
        }
        return result;
      }

      await DioClient.instance.ensureInitialized();
      final loginUri = _buildLoginUri(serviceUrl);
      final response = await _sendWithProxyFallback<String>(
        label: '统一认证会话校验',
        request: (dio, token) => dio.getUri<String>(
          loginUri,
          cancelToken: token,
          options: Options(
            responseType: ResponseType.plain,
            followRedirects: false,
            validateStatus: (status) => status != null && status < 1000,
            headers: {'Referer': loginUri.toString()},
          ),
        ),
      );

      final statusCode = response.statusCode ?? 0;
      final location = response.headers.value('location') ?? '';
      final html = response.data ?? '';
      final hasActiveSession = (statusCode == 302 || statusCode == 303)
          ? isUnifiedAuthAuthenticatedUrl(
                  _resolveUri(loginUri, location).toString(),
                ) ||
                urlHasCasTicket(location)
          : statusCode >= 200 &&
                statusCode < 300 &&
                !looksLikeUnifiedAuthLoginHtml(html);

      if (!hasActiveSession) {
        final explicitlyExpired =
            statusCode == 401 ||
            statusCode == 901 ||
            (statusCode == 200 && looksLikeUnifiedAuthLoginHtml(html)) ||
            ((statusCode == 302 || statusCode == 303) &&
                isUnifiedAuthLoginEntryUrl(
                  _resolveUri(loginUri, location).toString(),
                ));
        if (!explicitlyExpired) return null;
        if (revisionAtStart != _sessionRevision) return null;
        AppLogger.instance.auth(LogLevel.warn, '统一认证会话已失效，标记登出');
        await _markLoggedOutBestEffort();
        return false;
      }

      if (location.isNotEmpty) {
        try {
          await _followRedirectChain(loginUri, location);
        } catch (_) {}
      }

      if (revisionAtStart != _sessionRevision) return null;
      if (!isLoggedIn) return null;

      // 探测不提交新身份纪元。只有真实登录交换才推进 epoch。
      if (_sessionValidationSyncWebViewCookies['$serviceUrl#$revisionAtStart'] ==
          true) {
        unawaited(_syncCookiesToWebViewSafely());
      }
      return true;
    } on DioException catch (error) {
      final vpnHint = await _buildVpnTroubleshootingHint();
      AppLogger.instance.auth(
        LogLevel.error,
        '统一认证会话校验失败: ${error.type} ${error.message}$vpnHint',
      );
      return null;
    } catch (error) {
      final vpnHint = await _buildVpnTroubleshootingHint();
      AppLogger.instance.auth(LogLevel.error, '统一认证会话校验异常: $error$vpnHint');
      return null;
    }
  }

  Future<String> _buildVpnTroubleshootingHint() async {
    try {
      final results = await Connectivity().checkConnectivity();
      if (!results.contains(ConnectivityResult.vpn)) return '';
      return '。检测到 VPN/TUN，请在 Mihomo 中排除 edu.zjxu.jxucampushub，或将 *.zjxu.edu.cn 设为 DIRECT';
    } catch (_) {
      return '';
    }
  }

  Dio _createProxyFallbackDio() {
    final baseOptions = _dio.options;
    final client = Dio(
      BaseOptions(
        baseUrl: baseOptions.baseUrl,
        connectTimeout: baseOptions.connectTimeout,
        receiveTimeout: baseOptions.receiveTimeout,
        sendTimeout: baseOptions.sendTimeout,
        headers: Map<String, dynamic>.from(baseOptions.headers),
        followRedirects: baseOptions.followRedirects,
        validateStatus: baseOptions.validateStatus,
      ),
    );
    client.interceptors.add(buildCookieInterceptor(_cookieJar));
    applyProxyModeToDio(client, ignoreSystemProxy: false);
    final override = debugProxyFallbackAdapter;
    if (override != null) {
      client.httpClientAdapter.close();
      client.httpClientAdapter = override;
    }
    return client;
  }

  bool _shouldRetryWithSystemProxyForAny(Object error) {
    return shouldRetryWithSystemProxyForError(
      error,
      ignoreSystemProxy: NetworkSettings.instance.ignoreSystemProxy.value,
    );
  }

  Future<Response<T>> _sendWithProxyFallback<T>({
    required String label,
    required Future<Response<T>> Function(Dio dio, CancelToken token) request,
    CancelToken? cancelToken,
  }) async {
    Uri? requestUri;
    // ponytail: overlapping sends on the same Dio can clobber requestUri.
    final capture = InterceptorsWrapper(
      onRequest: (options, handler) {
        requestUri = options.uri;
        handler.next(options);
      },
    );

    Future<Response<T>> send(Dio dio) async {
      if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
      final token = CancelToken();
      unawaited(cancelToken?.whenCancel.then((error) => token.cancel(error)));
      dio.interceptors.add(capture);
      try {
        return await request(dio, token).timeout(_requestTimeout);
      } finally {
        dio.interceptors.remove(capture);
        // Future.timeout alone leaves the socket and cookie response alive.
        token.cancel('CAS request finished or timed out');
      }
    }

    try {
      return await send(_dio);
    } catch (error) {
      if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
      if (!_shouldRetryWithSystemProxyForAny(error)) rethrow;
      final target = requestUri ?? _uriFromError(error);
      if (target == null || await resolveHttpProxyForUri(target) == null) {
        rethrow;
      }
      final reason = describeSystemProxyRetryReason(error);
      AppLogger.instance.auth(
        LogLevel.warn,
        '$label 直连失败（$reason），尝试通过 HTTP_PROXY 环境代理重试',
      );
      final fallbackDio = _createProxyFallbackDio();
      try {
        return await send(fallbackDio);
      } finally {
        fallbackDio.close(force: true);
      }
    }
  }

  Uri? _uriFromError(Object error) {
    if (error is DioException) return error.requestOptions.uri;
    return null;
  }

  Future<Uint8List> fetchCaptcha({
    String serviceUrl = defaultServiceUrl,
    CancelToken? cancelToken,
  }) async {
    // 兼容包装：走 challenge 事务准备，手动 UI 只消费图片字节。
    try {
      final challenge = await prepareCaptchaChallenge(
        serviceUrl: serviceUrl,
        cancelToken: cancelToken,
      );
      return challenge.bytes;
    } on UnifiedAuthIncompleteSessionException catch (error) {
      throw UnifiedAuthCaptchaException(error.message);
    }
  }

  Future<UnifiedAuthLoginResult> login(
    String username,
    String password,
    String captcha, {
    String serviceUrl = defaultServiceUrl,
    String? challengeId,
    CancelToken? cancelToken,
  }) async {
    if (challengeId != null) {
      return submitCaptchaChallenge(
        challengeId: challengeId,
        username: username,
        password: password,
        captcha: captcha,
        cancelToken: cancelToken,
      );
    }
    // 兼容路径：只引用「当前」challenge（由 fetchCaptcha/prepare 发出），
    // 绝不重新初始化上下文。没有当前 challenge 即视为过期。
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    final revisionAtStart = _sessionRevision;
    final attempt = _captchaChallenges.consumeCurrent(
      accountRevision: revisionAtStart,
    );
    if (attempt == null) {
      return UnifiedAuthLoginFailure(
        '验证码已失效，请刷新后重试',
        kind: AuthFailureKind.staleOperation,
      );
    }
    return _submitUnifiedLogin(
      context: attempt.context,
      username: username,
      password: password,
      captcha: captcha,
      revisionAtStart: revisionAtStart,
      attemptGeneration: attempt.generation,
      cancelToken: cancelToken,
    );
  }

  Future<void> syncCookiesToWebView() async {
    debugWebViewCookieSyncCalls++;
    final existing = _cookieSyncFuture;
    if (existing != null) {
      await existing;
      return;
    }

    final future = _syncCookiesToWebViewInternal();
    _cookieSyncFuture = future;
    try {
      await future;
    } finally {
      if (identical(_cookieSyncFuture, future)) {
        _cookieSyncFuture = null;
      }
    }
  }

  /// 同步 [targetUrl] 所需 Cookie；目标 host 写入失败向上抛。
  Future<void> syncCookiesToWebViewForUrl(String targetUrl) async {
    final override = debugSyncCookiesToWebViewForUrlOverride;
    if (override != null) {
      await override(targetUrl);
      return;
    }
    await syncCookiesToWebView();

    final uri = Uri.parse(targetUrl);
    final cookies = await _cookieJar.loadForRequest(uri);
    for (final cookie in cookies) {
      await _setWebViewCookie(uri, cookie);
    }
  }

  Future<void> _syncCookiesToWebViewInternal() async {
    await DioClient.instance.ensureInitialized();
    // loadForRequest 需要带 path 的完整 URI 才能匹配到子路径 cookie
    final uris = [
      Uri.parse('$_newcaOrigin/cas/login'),
      Uri.parse('$_serviceHallOrigin/webroot/decision/view/form'),
      Uri.parse(_paymentOrigin),
      Uri.parse('$_libraryOrigin/Info/Thirdparty/ssoFromDingDing'),
    ];

    for (final uri in uris) {
      final cookies = await _cookieJar.loadForRequest(uri);
      for (final cookie in cookies) {
        try {
          await _setWebViewCookie(uri, cookie);
        } catch (error) {
          AppLogger.instance.auth(
            LogLevel.error,
            '同步 Cookie 失败 ${uri.host}/${cookie.name}: $error',
          );
        }
      }
    }
  }

  Future<void> markLoggedOut() async {
    // 先改内存并通知；登出也 bump revision，避免 in-flight restore 复活会话。
    _touchSessionRevision();
    _sessionActive = false;
    currentAccount = null;

    _captchaChallenges.invalidate();
    notifyListeners();
    try {
      // 持久撤销：写 inactive 并推进 epoch，使任何携带旧 epoch 的迟到登录
      // 提交（AuthSessionPersistence.commit）被拒绝，不会复活旧身份。
      await AuthSessionPersistence.instance.revoke(
        CredentialSessionDomain.unified,
      );
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '统一认证会话清理失败（不影响登出状态）',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 冷恢复会话元数据。同账号不通知；revision 漂移则丢弃本次读取。
  Future<void> restoreSession({bool syncWebViewCookies = true}) async {
    final revisionAtRead = _sessionRevision;
    final loader = debugSessionMetadataLoader;
    final account = loader != null
        ? await loader()
        : await CredentialStore.instance.loadUnifiedAuthSession();
    if (revisionAtRead != _sessionRevision) {
      AppLogger.instance.auth(LogLevel.debug, '统一认证冷恢复放弃：存储读取期间登录态已变化');
      return;
    }
    final trustedAccount = account?.trim();
    if (trustedAccount == null || trustedAccount.isEmpty) return;
    final identityChanged = currentAccount != trustedAccount || !isLoggedIn;
    _applySessionIdentity(active: true, account: trustedAccount);
    if (syncWebViewCookies) {
      unawaited(_syncCookiesToWebViewSafely());
    }
    if (identityChanged) {
      notifyListeners();
    }
  }

  /// 只清 CAS host Cookie，不过 `delete(uri, true)`（会误删 `.zjxu.edu.cn`）。
  Future<void> _clearCasOriginCookies() async {
    final origin = Uri.parse('$_newcaOrigin/');
    await _cookieJar.delete(origin);
    final host = origin.host;
    final expired = <io.Cookie>[];
    for (final domain in [host, '.$host']) {
      final paths = _cookieJar.domainCookies[domain];
      if (paths == null) continue;
      for (final pathEntry in paths.entries) {
        for (final name in pathEntry.value.keys) {
          expired.add(
            io.Cookie(name, '')
              ..domain = host
              ..path = pathEntry.key
              ..expires = DateTime.fromMillisecondsSinceEpoch(0),
          );
        }
      }
    }
    if (expired.isEmpty) return;
    await _cookieJar.saveFromResponse(origin, expired);
  }

  Future<void> _syncCookiesToWebViewSafely() async {
    try {
      await syncCookiesToWebView();
    } catch (error) {
      AppLogger.instance.auth(LogLevel.error, '统一认证 Cookie 延迟同步失败: $error');
    }
  }

  Future<void> _setWebViewCookie(Uri uri, io.Cookie cookie) async {
    final domain = (cookie.domain ?? '').trim();
    final path = (cookie.path ?? '').trim();
    await (_cookieManager ??= CookieManager.instance()).setCookie(
      url: WebUri('${uri.scheme}://${uri.host}/'),
      name: cookie.name,
      value: cookie.value,
      domain: domain.isNotEmpty ? domain : uri.host,
      path: path.isNotEmpty ? path : '/',
      isSecure: cookie.secure,
      isHttpOnly: cookie.httpOnly,
      expiresDate: cookie.expires?.millisecondsSinceEpoch,
    );
  }

  Future<_UnifiedAuthLoginContext> _refreshLoginContext(
    String serviceUrl, {
    CancelToken? cancelToken,
  }) async {
    // 重新获取登录页会刷新 lt/execution；任何已备好的验证码事务立即失效，
    // 防止「图片与表单上下文不匹配」的提交（提交前禁止偷偷 refetch）。
    _captchaChallenges.invalidate();
    if (isLoggedIn) {
      return _UnifiedAuthLoginContext(
        serviceUrl: serviceUrl,
        lt: '',
        execution: '',
        actionUri: _buildLoginUri(serviceUrl),
      );
    }

    await DioClient.instance.ensureInitialized();
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    final revisionAtStart = _sessionRevision;
    if (!isLoggedIn) {
      await _clearCasOriginCookies();
    }
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    if (revisionAtStart != _sessionRevision) {
      AppLogger.instance.auth(LogLevel.debug, '统一认证登录上下文放弃：清 Cookie 期间登录态已变化');
      throw UnifiedAuthIncompleteSessionException('统一认证登录上下文已过期，请重试');
    }
    if (isLoggedIn) {
      return _UnifiedAuthLoginContext(
        serviceUrl: serviceUrl,
        lt: '',
        execution: '',
        actionUri: _buildLoginUri(serviceUrl),
      );
    }
    final loginUri = _buildLoginUri(serviceUrl);
    final response = await _sendWithProxyFallback<String>(
      label: '统一认证登录上下文',
      cancelToken: cancelToken,
      request: (dio, token) => dio.getUri<String>(
        loginUri,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (s) => s != null && s < 1000,
          headers: {'Referer': loginUri.toString()},
        ),
      ),
    );

    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    if (revisionAtStart != _sessionRevision) {
      AppLogger.instance.auth(LogLevel.debug, '统一认证登录上下文放弃：等待期间登录态已变化');
      throw UnifiedAuthIncompleteSessionException('统一认证登录上下文已过期，请重试');
    }

    final statusCode = response.statusCode ?? 0;
    final location = response.headers.value('location') ?? '';
    if ((statusCode == 302 || statusCode == 303) && location.isNotEmpty) {
      final lowerLocation = location.toLowerCase();
      if (!lowerLocation.contains('/cas/login')) {
        AppLogger.instance.auth(LogLevel.warn, '统一认证已有未知身份 session，拒绝写成已登录');
        throw UnifiedAuthIncompleteSessionException('统一认证会话身份未知，请刷新后重试');
      }
      // 302 回到 /cas/login，需要跟随获取登录页面
      final redirectUrl = _resolveUri(loginUri, location).toString();
      final casResp = await _sendWithProxyFallback<String>(
        label: '统一认证登录页重定向',
        cancelToken: cancelToken,
        request: (dio, token) => dio.get<String>(
          redirectUrl,
          cancelToken: token,
          options: Options(
            responseType: ResponseType.plain,
            headers: {'Referer': loginUri.toString()},
          ),
        ),
      );
      if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
      if (revisionAtStart != _sessionRevision) {
        AppLogger.instance.auth(LogLevel.debug, '统一认证登录上下文放弃：登录页重定向期间登录态已变化');
        throw UnifiedAuthIncompleteSessionException('统一认证登录上下文已过期，请重试');
      }
      final html = casResp.data ?? '';
      final lt = _extractHiddenField(html, 'lt');
      final execution = _extractHiddenField(html, 'execution');
      final action = _extractFormAction(html);
      final context = _UnifiedAuthLoginContext(
        serviceUrl: serviceUrl,
        lt: lt,
        execution: execution,
        actionUri: _resolveUri(loginUri, action),
      );

      return context;
    }

    final html = response.data ?? '';
    final lt = _extractHiddenField(html, 'lt');
    final execution = _extractHiddenField(html, 'execution');
    final action = _extractFormAction(html);
    final context = _UnifiedAuthLoginContext(
      serviceUrl: serviceUrl,
      lt: lt,
      execution: execution,
      actionUri: _resolveUri(loginUri, action),
    );

    return context;
  }

  Uri _buildLoginUri(String serviceUrl) {
    return Uri.parse('$_newcaOrigin/cas/login')
        .replace(queryParameters: {'service': serviceUrl});
  }

  Uri _resolveUri(Uri baseUri, String location) {
    if (location.isEmpty) return baseUri;
    final resolved = Uri.tryParse(location);
    if (resolved == null) return baseUri;
    if (resolved.hasScheme) return resolved;
    return baseUri.resolveUri(resolved);
  }

  Future<void> _followRedirectChain(
    Uri baseUri,
    String location, {
    CancelToken? cancelToken,
  }) async {
    var nextUri = _resolveUri(baseUri, location);
    for (var i = 0; i < 8; i++) {
      // CAS 完成认证后会把 service ticket 挂到下游 URL 上；这个
      // URL 必须真正 GET 一次，目标服务才能兑换 ticket 并建立自己的
      // 会话 Cookie。不能按 host 截断，因为 WebVPN 与 casClient 本身就是
      // 合法的下游目标。只有重定向链确实回到了不带有效 ticket 的
      // CAS 登录入口时才停止，避免登录页循环；for 上限继续防护其他循环。
      final nextUrl = nextUri.toString();
      if (isUnifiedAuthLoginEntryUrl(nextUrl) && !urlHasCasTicket(nextUrl)) {
        AppLogger.instance.auth(LogLevel.debug, '统一认证重定向链: 回到 CAS 登录入口，停止跟随');
        return;
      }

      final response = await _sendWithProxyFallback<String>(
        label: '统一认证重定向链',
        cancelToken: cancelToken,
        request: (dio, token) => dio.getUri<String>(
          nextUri,
          cancelToken: token,
          options: Options(
            responseType: ResponseType.plain,
            followRedirects: false,
            validateStatus: (status) => status != null && status < 1000,
            headers: {'Referer': baseUri.toString()},
          ),
        ),
      );

      final redirect = response.headers.value('location') ?? '';
      if (redirect.isEmpty) return;
      nextUri = _resolveUri(nextUri, redirect);
    }
  }

  @visibleForTesting
  bool isLoginSuccess(int? statusCode, String location, String html) {
    if (statusCode == 302 || statusCode == 303) {
      return isUnifiedAuthAuthenticatedUrl(location) ||
          urlHasCasTicket(location);
    }

    final lowerHtml = html.toLowerCase();
    if (looksLikeUnifiedAuthLoginHtml(lowerHtml)) return false;
    return lowerHtml.contains('登录中') ||
        lowerHtml.contains('/oauth/forward/') ||
        lowerHtml.contains('casclient/login');
  }

  @visibleForTesting
  String extractLoginFailureMessage(String html) {
    final match = RegExp(
      r'''id=["']msg["'][^>]*>([\s\S]*?)</[^>]+>''',
      caseSensitive: false,
    ).firstMatch(html);
    final message = _decodeHtmlEntities(
      (match?.group(1) ?? '').replaceAll(RegExp(r'<[^>]+>'), '').trim(),
    );
    if (message.isNotEmpty) return message;

    if (html.contains('用户名或密码错误') || html.contains('密码错误')) {
      return '一卡通账号或密码错误，请检查后重试';
    }
    if (html.contains('验证码错误') ||
        html.contains('验证码已失效') ||
        html.contains('验证码不正确')) {
      return '验证码错误或已过期，请刷新后重试';
    }

    return '统一认证登录失败，请检查账号、密码和验证码';
  }

  String _extractHiddenField(String html, String fieldName) {
    final pattern = RegExp(
      'name=["\']$fieldName["\'][^>]*value=["\']([^"\']+)["\']',
      caseSensitive: false,
    );
    return pattern.firstMatch(html)?.group(1)?.trim() ?? '';
  }

  String _extractFormAction(String html) {
    final pattern = RegExp(
      r'''<form[^>]+id=["']fm1["'][^>]+action=["']([^"']+)["']''',
      caseSensitive: false,
    );
    return pattern.firstMatch(html)?.group(1)?.trim() ?? '';
  }

  String _decodeHtmlEntities(String value) {
    return value
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&')
        .trim();
  }

  bool _isValidImage(Uint8List data) {
    if (data.length < 4) return false;
    if (data[0] == 0x89 &&
        data[1] == 0x50 &&
        data[2] == 0x4E &&
        data[3] == 0x47) {
      return true;
    }
    if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return true;
    if (data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46) return true;
    return false;
  }

  @visibleForTesting
  HttpClientAdapter? debugProxyFallbackAdapter;

  @visibleForTesting
  Future<bool?> Function(String serviceUrl)? debugSessionValidator;

  @visibleForTesting
  Future<void> Function(String targetUrl)?
  debugSyncCookiesToWebViewForUrlOverride;

  @visibleForTesting
  Future<String?> Function()? debugSessionMetadataLoader;

  /// 测试用：真实发起 WebView cookie 同步的次数。自动恢复路径必须保持 0
  /// （`syncWebViewCookies: false`），人工登录默认仍会同步。
  @visibleForTesting
  int debugWebViewCookieSyncCalls = 0;

  @visibleForTesting
  void debugSetSession({required bool active, String? account}) {
    _applySessionIdentity(active: active, account: account);
  }

  @visibleForTesting
  void debugReset() {
    _sessionActive = false;
    currentAccount = null;
    _sessionRevision = 0;
    _cookieManager = null;
    _cookieSyncFuture = null;
    _sessionValidationFutures.clear();
    _sessionValidationSyncWebViewCookies.clear();
    _captchaChallenges.invalidate();
    debugSessionValidator = null;
    debugSessionMetadataLoader = null;
    debugProxyFallbackAdapter = null;
    debugSyncCookiesToWebViewForUrlOverride = null;
    debugWebViewCookieSyncCalls = 0;
  }
}
