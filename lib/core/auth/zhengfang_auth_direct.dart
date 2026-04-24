part of 'zhengfang_auth.dart';

extension ZhengfangAuthDirectExtension on ZhengfangAuth {
  /// 设置连接模式
  void setMode(ZhengfangMode mode) {
    _mode = mode;
    _cachedCsrfToken = null;
    _contextIndicatesLoggedIn = false;
    DioClient.instance.updateBaseUrl(_baseUrl);
    DioClient.instance
        .ensureInitialized()
        .then((_) => DioClient.instance.updateBaseUrl(_baseUrl))
        .catchError((_) {});
    AppLogger.instance.auth(
      LogLevel.info,
      '教务系统连接模式切换为: ${mode == ZhengfangMode.direct ? "直连" : "WebVPN"}',
    );
    _notifyAuthListeners();
  }

  Future<Uint8List> fetchCaptcha() async {
    await DioClient.instance.ensureInitialized();
    await _refreshLoginContext();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final resp = await _sendWithProxyFallback<List<int>>(
      label: '教务验证码',
      request: (dio) => dio.get<List<int>>(
        '$_baseUrl/kaptcha',
        queryParameters: {'time': ts},
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Referer': _loginPageUrl},
        ),
      ),
    );

    final location = resp.headers.value('location') ?? '';
    if (isZhengfangGatewayLoginUrl(location)) {
      AppLogger.instance.auth(LogLevel.warn, '教务验证码请求被重定向到 WebVPN 登录页');
      throw CaptchaException('WebVPN 认证已过期，请重新登录');
    }

    final contentType = resp.headers.value('content-type') ?? '';
    if (contentType.contains('text/html')) {
      AppLogger.instance.auth(LogLevel.warn, '验证码返回 HTML，可能未在校园网环境');
      if (_mode == ZhengfangMode.direct) {
        throw CaptchaException('无法连接到教务系统，请确保在校园网环境或已连接VPN');
      } else {
        throw CaptchaException('WebVPN 认证已过期，请重新登录');
      }
    }

    final bytes = resp.data;
    if (bytes == null || bytes.isEmpty) {
      throw CaptchaException('验证码数据为空，请重试');
    }

    final data = Uint8List.fromList(bytes);

    if (!ZhengfangAuth._isValidImage(data)) {
      AppLogger.instance.auth(LogLevel.warn, '验证码数据非有效图片，可能未在校园网环境');
      if (_mode == ZhengfangMode.direct) {
        throw CaptchaException('无法连接到教务系统，请确保在校园网环境或已连接VPN');
      } else {
        throw CaptchaException('WebVPN 连接异常，请重试');
      }
    }

    AppLogger.instance.auth(LogLevel.info, '验证码获取成功, ${data.length} 字节');
    return data;
  }

  Future<LoginResult> login(
    String username,
    String password,
    String captcha,
  ) async {
    try {
      await DioClient.instance.ensureInitialized();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final csrftoken = await _ensureCsrfToken();
      if (csrftoken.isEmpty) {
        if (_contextIndicatesLoggedIn) {
          if (username.isNotEmpty) {
            currentStudentId = username;
            await CredentialStore.instance.saveZhengfangSession(username);
          }
          _sessionActive = true;
          AppLogger.instance.auth(LogLevel.info, '检测到教务已有有效会话，跳过登录请求');
          _notifyAuthListeners();
          return LoginSuccess();
        }
        return LoginFailure('初始化登录参数失败，请刷新验证码后重试');
      }

      final keyResp = await _sendWithProxyFallback<Map<String, dynamic>>(
        label: '教务登录公钥',
        request: (dio) => dio.get<Map<String, dynamic>>(
          '$_baseUrl/xtgl/login_getPublicKey.html',
          queryParameters: {'time': ts},
          options: Options(
            headers: {
              'Referer': _loginPageUrl,
              'X-Requested-With': 'XMLHttpRequest',
            },
          ),
        ),
      );
      final publicKeyRedirect = keyResp.headers.value('location') ?? '';
      if (isZhengfangGatewayLoginUrl(publicKeyRedirect)) {
        return LoginFailure('WebVPN 认证已过期，请重新登录');
      }
      final modulus = keyResp.data?['modulus'] as String?;
      final exponent = keyResp.data?['exponent'] as String?;
      if (modulus == null ||
          exponent == null ||
          modulus.isEmpty ||
          exponent.isEmpty) {
        return LoginFailure('获取登录公钥失败，请稍后重试');
      }

      final encryptedPwd = _encryptPassword(password, modulus, exponent);
      final loginResp = await _sendWithProxyFallback<String>(
        label: '教务登录',
        request: (dio) => dio.post<String>(
          '$_baseUrl/xtgl/login_slogin.html',
          queryParameters: {'time': ts},
          data: {
            'csrftoken': csrftoken,
            'language': 'zh_CN',
            'yhm': username,
            'mm': encryptedPwd,
            'yzm': captcha,
          },
          options: Options(
            contentType: 'application/x-www-form-urlencoded',
            followRedirects: false,
            responseType: ResponseType.plain,
            validateStatus: (s) => s != null && s < 400,
            headers: {'Referer': _loginPageUrl, 'Origin': _origin},
          ),
        ),
      );

      final location = loginResp.headers.value('location') ?? '';
      final html = loginResp.data ?? '';
      if (isZhengfangGatewayLoginUrl(location)) {
        AppLogger.instance.auth(LogLevel.warn, '教务系统登录被重定向到 WebVPN 登录页');
        return LoginFailure('WebVPN 认证已过期，请重新登录');
      }
      if (isLoginSuccess(loginResp.statusCode, location, html)) {
        currentStudentId = username;
        _sessionActive = true;
        _cachedCsrfToken = null;
        await CredentialStore.instance.saveZhengfangSession(username);
        AppLogger.instance.auth(
          LogLevel.info,
          '教务系统登录成功 [${_mode == ZhengfangMode.direct ? "直连" : "WebVPN"}]',
        );
        _notifyAuthListeners();
        return LoginSuccess();
      }

      final msg = extractLoginFailureMessage(html);
      AppLogger.instance.auth(LogLevel.warn, '教务系统登录失败: $msg');
      return LoginFailure(msg);
    } on DioException catch (e) {
      _cachedCsrfToken = null;
      AppLogger.instance.auth(
        LogLevel.error,
        '教务系统登录网络异常: ${e.type} ${e.message}',
      );
      return LoginFailure('网络错误：${e.message}');
    } catch (e) {
      _cachedCsrfToken = null;
      return LoginFailure('登录异常：$e');
    }
  }

  bool get isLoggedIn => _sessionActive;

  bool get isWebVpnLoggedIn => _webVpnSessionActive;

  void markWebVpnLoggedIn() {
    _webVpnSessionActive = true;
  }

  void markWebVpnLoggedOut() {
    _webVpnSessionActive = false;
  }

  void markLoggedIn() {
    _sessionActive = true;
    if (currentStudentId != null) {
      CredentialStore.instance.saveZhengfangSession(currentStudentId!);
    }
    _notifyAuthListeners();
  }

  Future<void> markLoggedOut() async {
    _sessionActive = false;
    currentStudentId = null;
    _cachedCsrfToken = null;
    _contextIndicatesLoggedIn = false;
    await CredentialStore.instance.clearZhengfangSession();
    _notifyAuthListeners();
  }

  Future<void> restoreSession() async {
    final studentId = await CredentialStore.instance.loadZhengfangSession();
    if (studentId != null) {
      currentStudentId = studentId;
      _sessionActive = true;
      _notifyAuthListeners();
    }
  }

  Future<void> logout() async {
    await DioClient.instance.ensureInitialized();
    try {
      await _dio.post<void>('$_baseUrl/xtgl/login_logoutAccount.html');
    } catch (_) {}
    await _clearZhengfangCookies();
    _sessionActive = false;
    currentStudentId = null;
    _cachedCsrfToken = null;
    _contextIndicatesLoggedIn = false;
    await CredentialStore.instance.clearZhengfangSession();
    _notifyAuthListeners();
  }

  Future<void> logoutWebVpn() async {
    await DioClient.instance.ensureInitialized();
    await _webVpnCookieJar.deleteAll();
    markWebVpnLoggedOut();
    _notifyAuthListeners();
  }

  Future<void> _refreshLoginContext() async {
    await _refreshCsrfToken();
  }

  Future<void> _clearZhengfangCookies() async {
    final uris = [
      Uri.parse('$ZhengfangAuth._directOrigin/'),
      Uri.parse('$ZhengfangAuth._directOrigin$ZhengfangAuth._directLoginPath'),
      Uri.parse('$ZhengfangAuth._directBase/'),
      Uri.parse(
        '${ZhengfangAuth._directOrigin}/jwglxt/xtgl/index_initMenu.html?jsdm=xs',
      ),
      Uri.parse(
        '$ZhengfangAuth._webVpnBase$ZhengfangAuth._webVpnJwglxtPrefix/',
      ),
      Uri.parse(_loginPageUrl),
    ];

    for (final uri in uris) {
      final cookies = await _cookieJar.loadForRequest(uri);
      if (cookies.isEmpty) continue;
      await _cookieJar.delete(uri);
    }
  }

  Future<void> _clearWebViewCookiesForUri(
    CookieManager cookieManager,
    Uri uri,
    List<io.Cookie> cookies,
  ) async {
    if (cookies.isEmpty) return;

    final rootUrls = <String>{
      '${uri.scheme}://${uri.host}/',
      if (uri.scheme == 'https') 'http://${uri.host}/',
    };
    final normalizedPath = (uri.path.isEmpty ? '/' : uri.path).trim();

    for (final cookie in cookies) {
      final domain = (cookie.domain ?? '').trim();
      final targetDomain = domain.isNotEmpty ? domain : uri.host;
      final targetPath = (cookie.path ?? '').trim().isNotEmpty
          ? cookie.path!.trim()
          : normalizedPath;

      for (final rootUrl in rootUrls) {
        try {
          await cookieManager.deleteCookie(
            url: WebUri(rootUrl),
            name: cookie.name,
            domain: targetDomain,
            path: '/',
          );
        } catch (_) {}
        try {
          await cookieManager.deleteCookie(
            url: WebUri(rootUrl),
            name: cookie.name,
            domain: targetDomain,
            path: targetPath,
          );
        } catch (_) {}
      }
    }
  }

  Future<String> _ensureCsrfToken() async {
    final token = _cachedCsrfToken?.trim();
    if (token != null && token.isNotEmpty) return token;
    return _refreshCsrfToken();
  }

  Future<String> _refreshCsrfToken() async {
    _contextIndicatesLoggedIn = false;
    final pageResp = await _sendWithProxyFallback<String>(
      label: '教务登录页上下文',
      request: (dio) => dio.get<String>(
        '$_baseUrl/xtgl/login_slogin.html',
        options: Options(
          responseType: ResponseType.plain,
          headers: {'Referer': _loginPageUrl},
        ),
      ),
    );

    final statusCode = pageResp.statusCode ?? 0;
    final location = pageResp.headers.value('location') ?? '';
    if (isZhengfangGatewayLoginUrl(location)) {
      AppLogger.instance.auth(LogLevel.warn, '检测到 WebVPN 登录页重定向，当前认证已过期');
      markLoggedOut();
      throw CaptchaException('WebVPN 认证已过期，请重新登录');
    }
    if (isLoginSuccess(statusCode, location, '')) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '检测到 302 重定向到首页，旧会话可能已过期，清除 Cookie 后重新获取登录页',
      );
      await _clearZhengfangCookies();
      _sessionActive = false;
      _cachedCsrfToken = null;
      _notifyAuthListeners();

      final retryResp = await _sendWithProxyFallback<String>(
        label: '教务登录页上下文重试',
        request: (dio) => dio.get<String>(
          '$_baseUrl/xtgl/login_slogin.html',
          options: Options(
            responseType: ResponseType.plain,
            headers: {'Referer': _loginPageUrl},
          ),
        ),
      );

      final retryLocation = retryResp.headers.value('location') ?? '';
      if (isZhengfangGatewayLoginUrl(retryLocation)) {
        AppLogger.instance.auth(
          LogLevel.warn,
          '清除 Cookie 后跳转到 WebVPN 登录页，需要重新认证',
        );
        await markLoggedOut();
        throw CaptchaException('WebVPN 认证已过期，请重新登录');
      }
      if (isLoginSuccess(retryResp.statusCode, retryLocation, '')) {
        _sessionActive = true;
        _cachedCsrfToken = null;
        _contextIndicatesLoggedIn = true;
        AppLogger.instance.auth(LogLevel.info, '清除 Cookie 后仍检测到有效会话');
        _notifyAuthListeners();
        return '';
      }

      final retryHtml = retryResp.data ?? '';
      final retryToken = extractCsrfFromHtml(retryHtml);
      if (retryToken.isNotEmpty) {
        _cachedCsrfToken = retryToken;
        _contextIndicatesLoggedIn = false;
        return retryToken;
      }

      AppLogger.instance.auth(LogLevel.warn, '清除 Cookie 后仍无法获取 CSRF Token');
      _contextIndicatesLoggedIn = false;
      return '';
    }

    final pageHtml = pageResp.data ?? '';
    final token = extractCsrfFromHtml(pageHtml);
    _cachedCsrfToken = token;
    if (token.isEmpty) {
      AppLogger.instance.auth(LogLevel.warn, 'CSRF Token 为空，可能连接异常');
      _contextIndicatesLoggedIn = false;
    } else {
      _contextIndicatesLoggedIn = false;
    }
    return token;
  }

  @visibleForTesting
  String extractCsrfFromHtml(String html) {
    final matchById = RegExp(
      r'''id=["']csrftoken["'][^>]*value=["']([^"']+)["']''',
    ).firstMatch(html);
    final matchByName = RegExp(
      r'''name=["']csrftoken["'][^>]*value=["']([^"']+)["']''',
    ).firstMatch(html);
    return (matchById?.group(1) ?? matchByName?.group(1) ?? '').trim();
  }

  @visibleForTesting
  bool isLoginSuccess(int? statusCode, String location, String html) {
    if (statusCode == 302 || statusCode == 303) {
      if (isZhengfangLoginEntryUrl(location)) return false;
      return isZhengfangAuthenticatedUrl(location);
    }
    return html.contains('/xtgl/index_initMenu.html') ||
        html.contains('/xtgl/index_cxYhxxIndex.html');
  }

  @visibleForTesting
  String extractLoginFailureMessage(String html) {
    final tipMatch = RegExp(
      r'''id=["']tips["'][^>]*>([\s\S]*?)</[^>]+>''',
      caseSensitive: false,
    ).firstMatch(html);
    if (tipMatch != null) {
      final message = decodeHtmlEntities(
        (tipMatch.group(1) ?? '').replaceAll(RegExp(r'<[^>]+>'), '').trim(),
      );
      if (message.isNotEmpty) return message;
    }

    if (html.contains('验证码')) return '验证码错误或已过期，请刷新后重试';
    if (html.contains('用户名') || html.contains('密码')) return '用户名或密码错误';
    return '登录失败，请检查用户名、密码和验证码';
  }

  @visibleForTesting
  String decodeHtmlEntities(String value) {
    var result = value.trim();
    for (var i = 0; i < 3; i++) {
      final decoded = result
          .replaceAll('&nbsp;', ' ')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&#39;', "'")
          .replaceAll('&amp;', '&');
      if (decoded == result) break;
      result = decoded;
    }
    return result.trim();
  }

  @visibleForTesting
  void debugSetSession({required bool active, String? studentId}) {
    _sessionActive = active;
    currentStudentId = active ? studentId : null;
    if (!active) {
      _cachedCsrfToken = null;
      _contextIndicatesLoggedIn = false;
    }
  }

  @visibleForTesting
  void debugReset() {
    _cachedCsrfToken = null;
    _contextIndicatesLoggedIn = false;
    _sessionActive = false;
    currentStudentId = null;
    _cachedCasExecution = null;
    _cachedCasLt = null;
    _cachedCasLoginUrl = null;
    _mode = ZhengfangMode.direct;
  }
}
