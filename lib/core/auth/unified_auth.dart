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
import 'credential_store.dart';

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

sealed class UnifiedAuthLoginResult {}

class UnifiedAuthLoginSuccess extends UnifiedAuthLoginResult {}

class UnifiedAuthLoginFailure extends UnifiedAuthLoginResult {
  UnifiedAuthLoginFailure(this.message);

  final String message;
}

class UnifiedAuthCaptchaException implements Exception {
  UnifiedAuthCaptchaException(this.message);

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

  _UnifiedAuthLoginContext? _cachedContext;
  bool _sessionActive = false;
  String? currentAccount;

  /// 会话身份修订号：登录/登出等真正身份变化时递增，供 [restoreSession]
  /// 在存储读取等待期间检测外部登录态变化（防旧 metadata 覆盖新状态）。
  int _sessionRevision = 0;

  void _touchSessionRevision() => _sessionRevision++;

  /// 真正改变登录态或账号时才推进修订号；同状态写入不 bump。
  void _applySessionIdentity({required bool active, String? account}) {
    final nextAccount = active ? account : null;
    if (_sessionActive == active && currentAccount == nextAccount) return;
    _touchSessionRevision();
    _sessionActive = active;
    currentAccount = nextAccount;
    if (!active) _cachedContext = null;
  }

  Future<void>? _cookieSyncFuture;
  final Map<String, Future<bool?>> _sessionValidationFutures = {};
  final Map<String, bool> _sessionValidationSyncWebViewCookies = {};

  bool get isLoggedIn => _sessionActive;

  Future<bool> prepareLogin({
    String serviceUrl = defaultServiceUrl,
    CancelToken? cancelToken,
  }) async {
    if (_sessionActive) return true;
    final context = await _refreshLoginContext(
      serviceUrl,
      cancelToken: cancelToken,
    );
    return _sessionActive && context.lt.isEmpty && context.execution.isEmpty;
  }

  Future<bool?> validateSession({
    String serviceUrl = defaultServiceUrl,
    bool syncWebViewCookies = true,
  }) {
    if (!_sessionActive) return Future.value(false);

    final existing = _sessionValidationFutures[serviceUrl];
    if (existing != null) {
      _sessionValidationSyncWebViewCookies[serviceUrl] =
          (_sessionValidationSyncWebViewCookies[serviceUrl] ?? false) |
          syncWebViewCookies;
      return existing;
    }

    _sessionValidationSyncWebViewCookies[serviceUrl] = syncWebViewCookies;
    final future = _validateSessionInner(serviceUrl: serviceUrl);
    _sessionValidationFutures[serviceUrl] = future;
    return future.whenComplete(() {
      if (identical(_sessionValidationFutures[serviceUrl], future)) {
        _sessionValidationFutures.remove(serviceUrl);
        _sessionValidationSyncWebViewCookies.remove(serviceUrl);
      }
    });
  }

  /// 登出清理：凭据存储失败不应改变调用方的失效结论（测试环境无 secure
  /// storage mock、真实环境存储异常都会在这里抛出）。
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
    try {
      final validator = debugSessionValidator;
      if (validator != null) {
        final result = await validator(serviceUrl);
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
        AppLogger.instance.auth(LogLevel.warn, '统一认证会话已失效，标记登出');
        await _markLoggedOutBestEffort();
        return false;
      }

      if (location.isNotEmpty) {
        try {
          await _followRedirectChain(loginUri, location);
        } catch (_) {}
      }

      final wasSessionActive = _sessionActive;
      _applySessionIdentity(active: true, account: currentAccount);
      if (currentAccount != null) {
        await CredentialStore.instance.saveUnifiedAuthSession(currentAccount!);
      }
      if (_sessionValidationSyncWebViewCookies[serviceUrl] == true) {
        unawaited(_syncCookiesToWebViewSafely());
      }
      if (!wasSessionActive) {
        notifyListeners();
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
    await DioClient.instance.ensureInitialized();
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    await _ensureLoginContext(serviceUrl, cancelToken: cancelToken);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final referer = _buildLoginUri(serviceUrl).toString();
    final captchaUri = Uri.parse('$_newcaOrigin/cas/captcha.html?t=$timestamp');
    final resp = await _sendWithProxyFallback<List<int>>(
      label: '统一认证验证码',
      cancelToken: cancelToken,
      request: (dio, token) => dio.getUri<List<int>>(
        captchaUri,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Referer': referer},
        ),
      ),
    );

    final contentType = resp.headers.value('content-type') ?? '';
    if (contentType.contains('text/html')) {
      AppLogger.instance.auth(LogLevel.warn, '统一认证验证码返回 HTML，可能服务不可用');
      throw UnifiedAuthCaptchaException('统一认证验证码加载失败，请稍后重试');
    }

    final bytes = resp.data;
    if (bytes == null || bytes.isEmpty) {
      throw UnifiedAuthCaptchaException('统一认证验证码为空，请刷新后重试');
    }

    final data = Uint8List.fromList(bytes);
    if (!_isValidImage(data)) {
      AppLogger.instance.auth(LogLevel.warn, '统一认证验证码数据非有效图片');
      throw UnifiedAuthCaptchaException('统一认证验证码无效，请刷新后重试');
    }

    AppLogger.instance.auth(LogLevel.info, '统一认证验证码获取成功, ${data.length} 字节');
    return data;
  }

  Future<UnifiedAuthLoginResult> login(
    String username,
    String password,
    String captcha, {
    String serviceUrl = defaultServiceUrl,
  }) async {
    try {
      await DioClient.instance.ensureInitialized();
      final context = await _ensureLoginContext(serviceUrl);
      if (context.lt.isEmpty || context.execution.isEmpty) {
        // 如果 session 已经在 _refreshLoginContext 中建立，直接返回成功
        if (_sessionActive) {
          AppLogger.instance.auth(LogLevel.info, '统一认证已有有效 session，跳过登录');
          // 保留原语义：已有 CAS session 时仍把本次提交的 username 记为当前账号。
          _applySessionIdentity(active: true, account: username);
          await CredentialStore.instance.saveUnifiedAuthSession(username);
          notifyListeners();
          return UnifiedAuthLoginSuccess();
        }
        AppLogger.instance.auth(LogLevel.warn, '统一认证初始化上下文缺失');
        return UnifiedAuthLoginFailure('统一认证初始化失败，请刷新验证码后重试');
      }

      final encryptedPassword = AuthCrypto.instance.encryptPassword(password);
      final referer = _buildLoginUri(serviceUrl).toString();
      final response = await _sendWithProxyFallback<String>(
        label: '统一认证登录',
        request: (dio, token) => dio.postUri<String>(
          context.actionUri,
          cancelToken: token,
          data: {
            'username': username,
            'password': encryptedPassword,
            'veriyCode': captcha,
            'lt': context.lt,
            'execution': context.execution,
            '_eventId': 'submit',
          },
          options: Options(
            contentType: 'application/x-www-form-urlencoded',
            responseType: ResponseType.plain,
            followRedirects: false,
            validateStatus: (status) => status != null && status < 1000,
            headers: {'Referer': referer, 'Origin': _newcaOrigin},
          ),
        ),
      );

      final location = response.headers.value('location') ?? '';
      final html = response.data ?? '';
      if (isLoginSuccess(response.statusCode, location, html)) {
        await _followRedirectChain(context.actionUri, location);
        unawaited(_syncCookiesToWebViewSafely());
        _applySessionIdentity(active: true, account: username);
        _cachedContext = null;
        await CredentialStore.instance.saveUnifiedAuthSession(username);
        AppLogger.instance.auth(LogLevel.info, '统一认证登录成功，已同步 WebView Cookie');
        notifyListeners();
        return UnifiedAuthLoginSuccess();
      }

      _cachedContext = null;
      final msg = extractLoginFailureMessage(html);
      AppLogger.instance.auth(LogLevel.warn, '统一认证登录失败: $msg');
      return UnifiedAuthLoginFailure(msg);
    } on DioException catch (error) {
      _cachedContext = null;
      AppLogger.instance.auth(
        LogLevel.error,
        '统一认证登录网络异常: ${error.type} ${error.message}',
      );
      return UnifiedAuthLoginFailure('统一认证网络异常：${error.message}');
    } catch (error) {
      _cachedContext = null;
      return UnifiedAuthLoginFailure('统一认证登录失败：$error');
    }
  }

  Future<void> syncCookiesToWebView() async {
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

  /// Synchronizes the shared session cookies needed by [targetUrl].
  ///
  /// The fixed origins above cover the common CAS destinations. A business
  /// flow may instead redirect to a service-specific host (for example JWC or
  /// WebVPN), so load that exact URI from the same cookie jar as well. Errors
  /// while writing target cookies deliberately propagate to the caller.
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
    // 内存状态与通知必须先行：持久化清理失败（存储层异常）不能阻断
    // notifyListeners，否则 UI 会停留在「已登录」而会话实际已失效。
    // 登出即使已是未登录也推进 revision：in-flight restore 不得拿旧
    // metadata 把会话复活。
    _touchSessionRevision();
    _sessionActive = false;
    currentAccount = null;
    _cachedContext = null;
    notifyListeners();
    try {
      await CredentialStore.instance.clearUnifiedAuthSession();
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '统一认证会话清理失败（不影响登出状态）',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 冷恢复持久化的会话元数据。
  ///
  /// 仅当身份/登录态真正变化时才 [notifyListeners]（同账号重复 restore
  /// 不再通知，避免调用方的 epoch 守卫把正常恢复误判为身份变更）；存储
  /// 读取等待期间若发生外部 login/logout（revision 变化），放弃套用本次
  /// 读取到的（可能已过期的）metadata，防止登出后旧会话被“复活”。
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
    if (account == null) return;
    final identityChanged = currentAccount != account || !_sessionActive;
    _applySessionIdentity(active: true, account: account);
    if (syncWebViewCookies) {
      unawaited(_syncCookiesToWebViewSafely());
    }
    if (identityChanged) {
      notifyListeners();
    }
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

  Future<_UnifiedAuthLoginContext> _ensureLoginContext(
    String serviceUrl, {
    CancelToken? cancelToken,
  }) async {
    final context = _cachedContext;
    if (context != null && context.serviceUrl == serviceUrl) {
      return context;
    }
    return _refreshLoginContext(serviceUrl, cancelToken: cancelToken);
  }

  Future<_UnifiedAuthLoginContext> _refreshLoginContext(
    String serviceUrl, {
    CancelToken? cancelToken,
  }) async {
    if (_sessionActive) {
      return _UnifiedAuthLoginContext(
        serviceUrl: serviceUrl,
        lt: '',
        execution: '',
        actionUri: _buildLoginUri(serviceUrl),
      );
    }

    await DioClient.instance.ensureInitialized();
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
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

    // CAS 返回 302 说明已有 session，直接跟随重定向完成认证
    final statusCode = response.statusCode ?? 0;
    final location = response.headers.value('location') ?? '';
    if ((statusCode == 302 || statusCode == 303) && location.isNotEmpty) {
      final lowerLocation = location.toLowerCase();
      if (!lowerLocation.contains('/cas/login')) {
        AppLogger.instance.auth(LogLevel.info, '统一认证已有 session，跟随重定向完成认证');
        await _followRedirectChain(
          loginUri,
          location,
          cancelToken: cancelToken,
        );
        if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
        unawaited(_syncCookiesToWebViewSafely());
        _applySessionIdentity(active: true, account: currentAccount);
        if (currentAccount != null) {
          await CredentialStore.instance.saveUnifiedAuthSession(
            currentAccount!,
          );
        }
        notifyListeners();
        // 返回空上下文，标记已认证
        final context = _UnifiedAuthLoginContext(
          serviceUrl: serviceUrl,
          lt: '',
          execution: '',
          actionUri: loginUri,
        );
        _cachedContext = context;
        return context;
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
      _cachedContext = context;
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
    _cachedContext = context;
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

  /// 测试钩子：替换 [syncCookiesToWebViewForUrl] 的 CookieManager 写入，
  /// 避免 widget 测试因真实文件/插件 I/O 无法完成而挂起。
  @visibleForTesting
  Future<void> Function(String targetUrl)?
  debugSyncCookiesToWebViewForUrlOverride;

  /// 测试钩子：替换 [restoreSession] 的会话元数据读取，用于模拟存储读取
  /// 等待期间发生外部 login/logout。
  @visibleForTesting
  Future<String?> Function()? debugSessionMetadataLoader;

  @visibleForTesting
  void debugSetSession({required bool active, String? account}) {
    _applySessionIdentity(active: active, account: account);
  }

  /// 测试钩子：写入空 lt/execution 的已建立登录上下文，走 [login] 快速路径。
  @visibleForTesting
  void debugSeedEstablishedLoginContext({String? serviceUrl}) {
    final url = serviceUrl ?? defaultServiceUrl;
    _cachedContext = _UnifiedAuthLoginContext(
      serviceUrl: url,
      lt: '',
      execution: '',
      actionUri: _buildLoginUri(url),
    );
  }

  @visibleForTesting
  void debugReset() {
    _cachedContext = null;
    _sessionActive = false;
    currentAccount = null;
    _sessionRevision = 0;
    _cookieManager = null;
    _cookieSyncFuture = null;
    _sessionValidationFutures.clear();
    _sessionValidationSyncWebViewCookies.clear();
    debugSessionValidator = null;
    debugSessionMetadataLoader = null;
    debugProxyFallbackAdapter = null;
    debugSyncCookiesToWebViewForUrlOverride = null;
  }
}
