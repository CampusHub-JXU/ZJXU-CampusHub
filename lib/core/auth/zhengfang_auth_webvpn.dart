part of 'zhengfang_auth.dart';

extension ZhengfangAuthWebVpnExtension on ZhengfangAuth {
  /// 同步 WebVPN Cookie 到 WebView
  Future<void> syncWebVpnCookiesToWebView() async {
    if (_mode != ZhengfangMode.webVpn) return;
    await DioClient.instance.ensureInitialized();

    final cookieManager = CookieManager.instance();
    final uris = [
      Uri.parse('${ZhengfangAuth._webVpnBase}/'),
      Uri.parse(_loginPageUrl),
      Uri.parse(
        '${ZhengfangAuth._webVpnBase}${ZhengfangAuth._webVpnJwglxtPrefix}/',
      ),
    ];

    for (final uri in uris) {
      try {
        final cookies = await _webVpnCookieJar.loadForRequest(uri);
        // WebView may still hold an older HttpOnly WebVPN ticket. Android's
        // CookieManager does not reliably replace that cookie in-place, which
        // leaves Dio authenticated while the embedded page is redirected back
        // to login. Remove matching cookies before writing the current jar.
        await _clearWebViewCookiesForUri(cookieManager, uri, cookies);
        for (final cookie in cookies) {
          final domain = (cookie.domain ?? '').trim();
          await cookieManager.setCookie(
            url: WebUri('${uri.scheme}://${uri.host}/'),
            name: cookie.name,
            value: cookie.value,
            domain: domain.isNotEmpty ? domain : uri.host,
            path: (cookie.path ?? '').trim().isNotEmpty
                ? cookie.path!.trim()
                : '/',
            isSecure: cookie.secure,
            isHttpOnly: cookie.httpOnly,
            expiresDate: cookie.expires?.millisecondsSinceEpoch,
          );
        }

        final syncedCookies = await cookieManager.getCookies(
          url: WebUri('${uri.scheme}://${uri.host}${uri.path}'),
        );
        final expectedValues = {
          for (final cookie in cookies) cookie.name: cookie.value,
        };
        final syncedValues = {
          for (final cookie in syncedCookies) cookie.name: cookie.value,
        };
        final mismatchCount = expectedValues.entries
            .where((entry) => syncedValues[entry.key] != entry.value)
            .length;
        if (mismatchCount > 0) {
          AppLogger.instance.auth(
            LogLevel.warn,
            'WebVPN Cookie 同步不完整: ${uri.host}${uri.path} '
            '($mismatchCount 项未更新)',
          );
        }
      } catch (e) {
        AppLogger.instance.auth(LogLevel.error, '同步 WebVPN Cookie 失败: $e');
      }
    }
  }

  /// 同步直连教务系统 Cookie 到 WebView
  Future<void> syncDirectCookiesToWebView() async {
    if (_mode != ZhengfangMode.direct) return;
    await DioClient.instance.ensureInitialized();

    final cookieManager = CookieManager.instance();
    final uris = [
      Uri.parse('${ZhengfangAuth._directOrigin}/'),
      Uri.parse(
        '${ZhengfangAuth._directOrigin}${ZhengfangAuth._directLoginPath}',
      ),
      Uri.parse('${ZhengfangAuth._directBase}/'),
      Uri.parse(
        '${ZhengfangAuth._directOrigin}/jwglxt/xtgl/index_initMenu.html?jsdm=xs',
      ),
    ];

    for (final uri in uris) {
      try {
        final cookies = await _cookieJar.loadForRequest(uri);
        await _clearWebViewCookiesForUri(cookieManager, uri, cookies);
        for (final cookie in cookies) {
          final domain = (cookie.domain ?? '').trim();
          await cookieManager.setCookie(
            url: WebUri('${uri.scheme}://${uri.host}/'),
            name: cookie.name,
            value: cookie.value,
            domain: domain.isNotEmpty ? domain : uri.host,
            path: (cookie.path ?? '').trim().isNotEmpty
                ? cookie.path!.trim()
                : '/',
            isSecure: cookie.secure,
            isHttpOnly: cookie.httpOnly,
            expiresDate: cookie.expires?.millisecondsSinceEpoch,
          );
        }
        final syncedCookies = await cookieManager.getCookies(
          url: WebUri('${uri.scheme}://${uri.host}${uri.path}'),
        );
        if (syncedCookies.isEmpty) {
          continue;
        }
      } catch (e) {
        AppLogger.instance.auth(LogLevel.error, '同步教务系统 Cookie 失败: $e');
      }
    }
  }

  Future<Map<String, String>> buildWebViewHeaders(String targetUrl) async {
    await DioClient.instance.ensureInitialized();

    final resolvedUrl = resolvePortalUrl(targetUrl);
    final uri = Uri.parse(resolvedUrl);
    final cookies =
        await (_mode == ZhengfangMode.webVpn ? _webVpnCookieJar : _cookieJar)
            .loadForRequest(uri);
    final cookieHeader = cookies
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');

    return {
      if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
      'Referer': _loginPageUrl,
    };
  }

  /// 同步 Cookie 到 WebView (根据当前模式)
  Future<void> syncCookiesToWebView() async {
    if (_mode == ZhengfangMode.webVpn) {
      await syncWebVpnCookiesToWebView();
    } else {
      await syncDirectCookiesToWebView();
    }
  }

  /// 校验教务会话是否仍然有效。
  /// 返回:
  /// - `true`: 会话有效
  /// - `false`: 会话失效（会自动标记登出）
  /// - `null`: 校验请求失败（网络异常），不变更当前登录态
  Future<bool?> validateSession() async {
    if (!_sessionActive) return false;

    await DioClient.instance.ensureInitialized();
    final indexUrl = '$_baseUrl/xtgl/index_initMenu.html';

    try {
      final response = await _sendWithProxyFallback<String>(
        label: '教务会话校验',
        request: (dio) => dio.get<String>(
          indexUrl,
          queryParameters: {'jsdm': 'xs'},
          options: Options(
            responseType: ResponseType.plain,
            followRedirects: false,
            validateStatus: (status) => status != null && status < 1000,
            headers: {'Referer': _loginPageUrl},
          ),
        ),
      );

      final statusCode = response.statusCode ?? 0;
      final location = response.headers.value('location') ?? '';
      final html = (response.data ?? '').toLowerCase();

      final redirectedToLogin =
          (statusCode == 302 || statusCode == 303) &&
          (location.toLowerCase().contains('login_slogin') ||
              location.toLowerCase().contains('kaptcha') ||
              isZhengfangGatewayLoginUrl(location));
      final loginPageReturned =
          statusCode == 200 && looksLikeZhengfangLoginHtml(html);

      if (redirectedToLogin || loginPageReturned) {
        AppLogger.instance.auth(LogLevel.warn, '教务会话已失效，自动标记为未登录');
        markLoggedOut();
        return false;
      }

      return true;
    } on DioException catch (e) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '教务会话校验失败（网络异常）: ${e.type} ${e.message}',
      );
      return null;
    } catch (e) {
      AppLogger.instance.auth(LogLevel.warn, '教务会话校验失败（未知异常）: $e');
      return null;
    }
  }

  /// 校验指定 WebVPN 代理目标是否已有有效登录态。
  /// 返回:
  /// - `true`: WebVPN session 有效
  /// - `false`: 已明确失效，需要重新登录
  /// - `null`: 校验失败（网络异常），不下结论
  Future<bool?> validateWebVpnProxySession(String targetUrl) async {
    await DioClient.instance.ensureInitialized();
    final probeUrl = buildWebVpnProxyUrl(targetUrl);

    try {
      final response = await _sendWithProxyFallback<String>(
        label: 'WebVPN 目标会话校验',
        request: (dio) => dio.get<String>(
          probeUrl,
          options: Options(
            responseType: ResponseType.plain,
            followRedirects: false,
            validateStatus: (status) => status != null && status < 1000,
            headers: {'Referer': '${ZhengfangAuth._webVpnBase}/'},
          ),
        ),
      );

      final statusCode = response.statusCode ?? 0;
      final location = response.headers.value('location') ?? '';
      final resolvedLocation = location.isEmpty
          ? ''
          : Uri.parse(probeUrl).resolve(location).toString();
      final html = response.data ?? '';
      final realUrl = response.realUri.toString();

      final redirectedToLogin =
          (statusCode == 302 || statusCode == 303) &&
          isZhengfangLoginEntryUrl(resolvedLocation);
      final landedOnLogin = _looksLikeWebVpnAuthResponse(realUrl, html);

      if (redirectedToLogin || landedOnLogin) {
        final canAttemptSso =
            UnifiedAuthService.instance.isLoggedIn || isWebVpnLoggedIn;
        if (canAttemptSso) {
          try {
            final retryResp = await _attemptWebVpnSessionRecovery(probeUrl);
            if (retryResp != null) {
              AppLogger.instance.auth(LogLevel.info, 'WebVPN 目标会话 SSO 已自动恢复');
              markWebVpnLoggedIn();
              return true;
            }
          } catch (_) {}
        }
        AppLogger.instance.auth(LogLevel.warn, 'WebVPN 目标会话已失效: $probeUrl');
        markWebVpnLoggedOut();
        return false;
      }

      markWebVpnLoggedIn();
      return true;
    } on DioException catch (e) {
      AppLogger.instance.auth(
        LogLevel.warn,
        'WebVPN 目标会话校验失败（网络异常）: ${e.type} ${e.message}',
      );
      return null;
    } catch (e) {
      AppLogger.instance.auth(LogLevel.warn, 'WebVPN 目标会话校验失败（未知异常）: $e');
      return null;
    }
  }

  Future<bool?> validateWebVpnTargetSession(String targetUrl) async {
    setMode(ZhengfangMode.webVpn);
    return validateWebVpnProxySession(targetUrl);
  }

  Future<bool?> ensureWebVpnGatewaySession({
    bool syncWebViewCookies = true,
  }) async {
    await DioClient.instance.ensureInitialized();

    // FR-1: 不再无条件切换为 WebVPN。先探测连接模式：
    // - 直连可达 → 切回直连模式，无需 WebVPN 网关会话，直接返回 true。
    // - WebVPN 可达 → 切换 WebVPN 并建立网关会话。
    // - 两者均不可达 → 返回 null，网络异常不代表会话失效。
    final mode = await ConnectModeResolver.instance.resolve();
    if (mode == ZhengfangMode.direct) {
      if (_mode != ZhengfangMode.direct) {
        setMode(ZhengfangMode.direct);
      }
      return true;
    }
    if (mode != ZhengfangMode.webVpn) {
      AppLogger.instance.auth(LogLevel.warn, 'WebVPN 网关会话不可用：直连与 WebVPN 均不可达');
      return null;
    }
    setMode(ZhengfangMode.webVpn);

    final unifiedAuthActive = await UnifiedAuthService.instance.validateSession(
      serviceUrl: ZhengfangAuth.webVpnGatewayServiceUrl,
      syncWebViewCookies: false,
    );
    if (unifiedAuthActive != true) {
      if (unifiedAuthActive == false) {
        markWebVpnLoggedOut();
      }
      return unifiedAuthActive;
    }

    try {
      final response = await _sendWithProxyFallback<String>(
        label: 'WebVPN 网关会话校验',
        request: (dio) => dio.get<String>(
          ZhengfangAuth.webVpnGatewayLoginUrl,
          options: Options(
            responseType: ResponseType.plain,
            followRedirects: true,
            validateStatus: (status) => status != null && status < 1000,
            headers: {'Referer': '${ZhengfangAuth._webVpnBase}/'},
          ),
        ),
      );

      final html = response.data ?? '';
      final realUrl = response.realUri.toString();
      if (_looksLikeWebVpnAuthResponse(realUrl, html)) {
        AppLogger.instance.auth(LogLevel.warn, 'WebVPN 网关会话恢复后仍命中登录页');
        markWebVpnLoggedOut();
        return false;
      }

      markWebVpnLoggedIn();
      if (syncWebViewCookies) {
        await syncWebVpnCookiesToWebView();
      }
      return true;
    } on DioException catch (e) {
      AppLogger.instance.auth(
        LogLevel.warn,
        'WebVPN 网关会话校验失败（网络异常）: ${e.type} ${e.message}',
      );
      return null;
    } catch (e) {
      AppLogger.instance.auth(LogLevel.warn, 'WebVPN 网关会话校验失败（未知异常）: $e');
      return null;
    }
  }

  bool _looksLikeWebVpnAuthResponse(String url, String html) {
    if (isZhengfangGatewayLoginUrl(url) || isZhengfangLoginEntryUrl(url)) {
      return true;
    }

    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.toLowerCase() != 'webvpn.zjxu.edu.cn') {
      return false;
    }

    final path = uri.path.toLowerCase();
    if (path == '/' || path == '/m/portal' || path == '/login') {
      return true;
    }

    return looksLikeUnifiedAuthLoginHtml(html);
  }

  Future<Response<String>?> _attemptWebVpnSessionRecovery(
    String probeUrl,
  ) async {
    final webVpnReady = await ensureWebVpnGatewaySession(
      syncWebViewCookies: false,
    );
    if (webVpnReady != true) {
      return null;
    }

    final retryResp = await _sendWithProxyFallback<String>(
      label: 'WebVPN 目标会话二次校验',
      request: (dio) => dio.get<String>(
        probeUrl,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: true,
          validateStatus: (status) => status != null && status < 1000,
          headers: {'Referer': '${ZhengfangAuth._webVpnBase}/'},
        ),
      ),
    );
    final retryHtml = retryResp.data ?? '';
    final retryUrl = retryResp.realUri.toString();
    if (_looksLikeWebVpnAuthResponse(retryUrl, retryHtml)) {
      return null;
    }
    return retryResp;
  }
}
