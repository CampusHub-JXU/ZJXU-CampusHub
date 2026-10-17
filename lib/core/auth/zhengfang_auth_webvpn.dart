part of 'zhengfang_auth.dart';

/// 网关确保结果：ready 三态 + 本次选中的连接模式。
class WebVpnGatewayEnsureResult {
  const WebVpnGatewayEnsureResult({required this.ready, this.selectedMode});

  final bool? ready;
  final ZhengfangMode? selectedMode;
}

/// 受信教务入口业务会话探测结果（fail closed）。
///
/// 与旧的 `bool?` 不同，本类型区分「需要教务登录」与「需要统一认证登录」，
/// 并强制把无法证明的情况归为 [unknown]，绝不 fail-open。
enum AcademicEntrySessionStatus {
  /// 有可证明的教务业务成功证据（本模式受信 origin 上的已认证教务页面）。
  authenticated,

  /// 明确落在教务（正方）登录入口 / 验证码页，需要教务登录。
  academicLoginRequired,

  /// 明确落在统一认证 / WebVPN 网关登录入口，需要统一认证登录。
  unifiedLoginRequired,

  /// 无法证明（未知状态 / 网络异常 / 跨域或不可识别的跳转 / 无成功签名的 200）。
  unknown,
}

/// 严格模式同步 Cookie 失败（仅教务 H5 入口准备使用）。
///
/// 抛出本异常即表示调用方**不得**据此判定入口 Ready。
class AcademicCookieSyncException implements Exception {
  const AcademicCookieSyncException(this.message);

  final String message;

  @override
  String toString() => 'AcademicCookieSyncException: $message';
}

/// 是否为本模式受信 origin 上已知的教务已认证页面。
bool _isAuthenticatedAcademicLocation(ZhengfangMode mode, String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final expectedHost = mode == ZhengfangMode.webVpn
      ? Uri.parse(ZhengfangAuth._webVpnBase).host
      : Uri.parse(ZhengfangAuth._directOrigin).host;
  if (uri.host.toLowerCase() != expectedHost.toLowerCase()) return false;
  return isZhengfangAuthenticatedUrl(url);
}

/// 200 响应体是否带正向的教务已认证页面签名。
///
/// 与 [ZhengfangAuth.isLoginSuccess] 对 200 响应的成功签名保持一致，不新增
/// 任何未经验证的标记；无法证明时调用方必须按 unknown 处理。
bool _looksLikeAuthenticatedAcademicHtml(String html) {
  final lower = html.toLowerCase();
  if (lower.isEmpty) return false;
  if (lower.contains('/xtgl/index_initmenu.html') ||
      lower.contains('/xtgl/index_cxyhxxindex.html')) {
    return true;
  }
  // 设备实测（2026-09-30，直连校园网）：已登录的 index_initMenu.html 返回
  // 200 + 学生菜单页，不含上面两个绝对路径，但带页面级 `sessionUserKey`
  // 与学生专属菜单链接（课表查询 / 个人信息）。登录页不会渲染学生菜单，
  // 两者同时命中才算正向证据。
  return lower.contains('sessionuserkey') &&
      (lower.contains('/kbcx/xskbcx_cxxskbcxindex.html') ||
          lower.contains('/xsxxxggl/xsgrxxwh_cxxsgrxx.html'));
}

/// 受信教务入口响应的**纯函数**分类（fail closed，无网络、无副作用）。
///
/// [probeTrustedEntrySession] 与登录后会话校验共用这一份判定，避免复制
/// bounce 检测逻辑。
@visibleForTesting
AcademicEntrySessionStatus classifyAcademicEntryResponse({
  required ZhengfangMode mode,
  required Uri requestUri,
  required int status,
  required String location,
  required String html,
}) {
  final resolvedLocation = location.isEmpty
      ? requestUri.toString()
      : requestUri.resolve(location).toString();

  // 登录页判定统一走 login_page_detection.dart：统一认证 / WebVPN 网关登录
  // 属于统一认证问题，教务登录入口 / 验证码页才是需要教务登录；两者同时命中
  // 时统一认证优先。正文只在 200 时参与判定。
  switch (classifyLoginExchange(
    realUrl: resolvedLocation,
    html: status == 200 ? html : null,
  )) {
    case LoginPageKind.unifiedAuth || LoginPageKind.webVpnGateway:
      return AcademicEntrySessionStatus.unifiedLoginRequired;
    case LoginPageKind.zhengfang:
      return AcademicEntrySessionStatus.academicLoginRequired;
    case null:
      break;
  }

  if (status == 302 || status == 303) {
    // 只有落在本模式受信 origin、且是已知教务已认证页面的跳转才算就绪；
    // 其它跳转（跨域 / 任意 / 不可识别）一律 unknown，绝不 fail-open。
    // 该正向判定复用 [isZhengfangAuthenticatedUrl]（与登录成功解析一致）。
    if (_isAuthenticatedAcademicLocation(mode, resolvedLocation)) {
      return AcademicEntrySessionStatus.authenticated;
    }
    return AcademicEntrySessionStatus.unknown;
  }
  if (status == 200) {
    // 200 未命中登录签名也不等于已登录：必须有正向已认证页面证据，否则
    // 不得判就绪。证据与 [ZhengfangAuth.isLoginSuccess] 的成功签名一致。
    if (_looksLikeAuthenticatedAcademicHtml(html)) {
      return AcademicEntrySessionStatus.authenticated;
    }
    return AcademicEntrySessionStatus.unknown;
  }
  // 401/403：业务接口语义即未认证，判需要教务登录。
  if (status == 401 || status == 403) {
    return AcademicEntrySessionStatus.academicLoginRequired;
  }
  // 其它状态（5xx / 304 / 未知 3xx）：不判失效也不判就绪。
  return AcademicEntrySessionStatus.unknown;
}

extension ZhengfangAuthWebVpnExtension on ZhengfangAuth {
  /// 同步 WebVPN Cookie 到 WebView（按当前全局模式，保留旧调用契约）。
  Future<void> syncWebVpnCookiesToWebView() async {
    if (_mode != ZhengfangMode.webVpn) return;
    await syncCookiesToWebViewForMode(ZhengfangMode.webVpn);
  }

  /// 同步直连教务系统 Cookie 到 WebView（按当前全局模式，保留旧调用契约）。
  Future<void> syncDirectCookiesToWebView() async {
    if (_mode != ZhengfangMode.direct) return;
    await syncCookiesToWebViewForMode(ZhengfangMode.direct);
  }

  /// 按**显式 [mode]** 同步教务 Cookie 到 WebView，不读取 / 不修改全局
  /// [_mode]，也不跨库复制 Cookie：直连用 `zhengfang` jar，WebVPN 用
  /// `unifiedAuth` 网关 jar。
  ///
  /// [isIdentityCurrent] 会在每个 Cookie 写副作用前复核；返回 false 立即
  /// 中止后续写入，避免把旧 owner 的 Cookie 写进新会话。
  ///
  /// [strict] 为 true 时是 **fail-closed** 模式（当前仅教务 H5 入口准备使用）：
  /// 相关 Cookie 的读取 / 清理 / 写入 / 校验任何一步失败、身份在校验期间变化，
  /// 或已认证会话读不到任何可同步 Cookie，都会抛
  /// [AcademicCookieSyncException]，调用方不得据此判定 Ready。默认 false 保留
  /// 旧的最佳努力语义（吞掉单个 URI 的失败并记日志）。
  Future<void> syncCookiesToWebViewForMode(
    ZhengfangMode mode, {
    bool Function()? isIdentityCurrent,
    bool strict = false,
  }) async {
    await DioClient.instance.ensureInitialized();

    final cookieManager = CookieManager.instance();
    final cookieJar = _cookieJarFor(mode);
    final uris = mode == ZhengfangMode.webVpn
        ? [
            Uri.parse('${ZhengfangAuth._webVpnBase}/'),
            Uri.parse(_loginPageUrlFor(mode)),
            Uri.parse(
              '${ZhengfangAuth._webVpnBase}${ZhengfangAuth._webVpnJwglxtPrefix}/',
            ),
          ]
        : [
            Uri.parse('${ZhengfangAuth._directOrigin}/'),
            Uri.parse(
              '${ZhengfangAuth._directOrigin}${ZhengfangAuth._directLoginPath}',
            ),
            Uri.parse('${ZhengfangAuth._directBase}/'),
            Uri.parse(
              '${ZhengfangAuth._directOrigin}/jwglxt/xtgl/index_initMenu.html?jsdm=xs',
            ),
          ];

    var loadedAnyCookie = false;

    for (final uri in uris) {
      if (isIdentityCurrent != null && !isIdentityCurrent()) {
        if (strict) {
          throw const AcademicCookieSyncException('Cookie 同步期间身份已变化');
        }
        return;
      }
      try {
        final cookies = await cookieJar.loadForRequest(uri);
        if (cookies.isNotEmpty) loadedAnyCookie = true;
        if (isIdentityCurrent != null && !isIdentityCurrent()) {
          if (strict) {
            throw const AcademicCookieSyncException('Cookie 同步期间身份已变化');
          }
          return;
        }
        // WebView may still hold an older HttpOnly session cookie. Android's
        // CookieManager does not reliably replace that cookie in-place, which
        // leaves Dio authenticated while the embedded page is redirected back
        // to login. Remove matching cookies before writing the current jar.
        await _clearWebViewCookiesForUri(
          cookieManager,
          uri,
          cookies,
          isIdentityCurrent: isIdentityCurrent,
          strict: strict,
        );
        for (final cookie in cookies) {
          if (isIdentityCurrent != null && !isIdentityCurrent()) {
            if (strict) {
              throw const AcademicCookieSyncException('Cookie 同步期间身份已变化');
            }
            return;
          }
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
        if (isIdentityCurrent != null && !isIdentityCurrent()) {
          if (strict) {
            throw const AcademicCookieSyncException('Cookie 同步期间身份已变化');
          }
          return;
        }
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
          if (strict) {
            throw AcademicCookieSyncException(
              '教务 Cookie 同步校验不完整: ${uri.host}${uri.path} '
              '($mismatchCount 项未更新)',
            );
          }
          AppLogger.instance.auth(
            LogLevel.warn,
            '教务 Cookie 同步不完整: ${uri.host}${uri.path} '
            '($mismatchCount 项未更新)',
          );
        }
      } on AcademicCookieSyncException {
        // 严格模式主动抛出的异常不得被下面的通用 catch 吞掉。
        rethrow;
      } catch (e) {
        if (strict) {
          throw AcademicCookieSyncException(
            '同步教务 Cookie 失败: ${uri.host}${uri.path}',
          );
        }
        AppLogger.instance.auth(LogLevel.error, '同步教务 Cookie 失败: $e');
      }
    }

    if (strict && !loadedAnyCookie) {
      throw const AcademicCookieSyncException('已认证会话未读到任何可同步的教务 Cookie');
    }
  }

  /// 按显式 [mode] 探测**受信教务入口**的业务会话，不修改全局 [_mode]，
  /// 不做任何登出 / 失效标记副作用。
  ///
  /// **fail closed**：只有拿到正向的教务已认证证据才返回
  /// [AcademicEntrySessionStatus.authenticated]；任何跨域 / 任意 / 不可识别的
  /// 跳转、无成功签名的 200、未知状态或网络异常一律返回
  /// [AcademicEntrySessionStatus.unknown]，绝不据此判就绪。
  /// 已知的统一认证 / WebVPN 网关登录归为
  /// [AcademicEntrySessionStatus.unifiedLoginRequired]，已知的教务登录页归为
  /// [AcademicEntrySessionStatus.academicLoginRequired]。
  Future<AcademicEntrySessionStatus> probeTrustedEntrySession({
    required ZhengfangMode mode,
    required String requestUrl,
    CancelToken? cancelToken,
  }) async {
    await DioClient.instance.ensureInitialized();
    final requestUri = Uri.tryParse(requestUrl);
    if (requestUri == null) return AcademicEntrySessionStatus.unknown;

    try {
      final response = await _sendWithProxyFallback<String>(
        label: '教务受信入口会话探测',
        mode: mode,
        cancelToken: cancelToken,
        request: (dio, token) => dio.get<String>(
          requestUrl,
          cancelToken: token,
          options: Options(
            responseType: ResponseType.plain,
            followRedirects: false,
            validateStatus: (status) => status != null && status < 1000,
            headers: {'Referer': _loginPageUrlFor(mode)},
          ),
        ),
      );

      return classifyAcademicEntryResponse(
        mode: mode,
        requestUri: requestUri,
        status: response.statusCode ?? 0,
        location: response.headers.value('location') ?? '',
        html: response.data ?? '',
      );
    } on DioException catch (error) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '教务受信入口会话探测失败（网络异常）: ${error.type} ${error.message}',
      );
      return AcademicEntrySessionStatus.unknown;
    } catch (error) {
      AppLogger.instance.auth(LogLevel.warn, '教务受信入口会话探测失败（未知异常）: $error');
      return AcademicEntrySessionStatus.unknown;
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

  /// 按显式 [mode] 构造 WebView 初始请求头，不读取 / 不修改全局 [_mode]。
  ///
  /// [resolvedUrl] 必须是调用方按同一 [mode] 构造好的最终 URL（直连为原始
  /// 地址，WebVPN 为代理地址）；本方法不再二次解析，避免依赖全局模式。
  Future<Map<String, String>> buildWebViewHeadersForMode({
    required ZhengfangMode mode,
    required String resolvedUrl,
  }) async {
    await DioClient.instance.ensureInitialized();

    final uri = Uri.parse(resolvedUrl);
    final cookies = await _cookieJarFor(mode).loadForRequest(uri);
    final cookieHeader = cookies
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');

    return {
      if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
      'Referer': _loginPageUrlFor(mode),
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
  /// - `false`: 会话失效（[revokeOnInvalid] 为 true 时按发起时 epoch 条件撤销）
  /// - `null`: 校验请求失败（网络异常），或探测期间会话已变化（不下结论）
  ///
  /// [revokeOnInvalid] 为 false 时是**无登出副作用探测**：guard 的恢复链路用它
  /// 只判定会话是否失效，不撤销任何会话，从而能继续走一次 OCR 自动登录。
  /// [mode] 显式指定校验所走的连接模式（默认当前全局模式）；恢复链路先按
  /// 探测结果校验、确认有效后再切换全局模式，校验本身不改全局模式。
  Future<bool?> validateSession({
    bool revokeOnInvalid = true,
    ZhengfangMode? mode,
  }) async {
    final effectiveMode = mode ?? _mode;
    if (!_sessionActive) return false;

    // 绑定发起时的 owner + revision + 持久 epoch：探测期间切号/同账号重登后，
    // 本次失效响应属于旧 owner，必须 fail closed，绝不登出新会话。
    final revisionAtStart = _sessionRevision;
    final accountAtStart = currentStudentId;
    // 无副作用探测（guard 路径）不需要 epoch，避免多余的持久读。
    final epochAtStart = revokeOnInvalid
        ? await durableAcademicEpochOrUnknown()
        : -1;

    await DioClient.instance.ensureInitialized();
    final indexUrl = '${_baseUrlFor(effectiveMode)}/xtgl/index_initMenu.html';

    try {
      final response = await _sendWithProxyFallback<String>(
        label: '教务会话校验',
        mode: effectiveMode,
        request: (dio, token) => dio.get<String>(
          indexUrl,
          queryParameters: {'jsdm': 'xs'},
          cancelToken: token,
          options: Options(
            responseType: ResponseType.plain,
            followRedirects: false,
            validateStatus: (status) => status != null && status < 1000,
            headers: {'Referer': _loginPageUrlFor(effectiveMode)},
          ),
        ),
      );

      final statusCode = response.statusCode ?? 0;
      final location = response.headers.value('location') ?? '';
      final html = (response.data ?? '').toLowerCase();

      // 教务会话校验只把教务登录入口 / 验证码页与网关登录视为失效；跳统一认证
      // 登录（`/cas/login`）是统一认证问题，不撤销教务会话（保持原口径）。
      final redirectedToLogin =
          (statusCode == 302 || statusCode == 303) &&
          classifyLoginUrl(
                location,
                kinds: const {
                  LoginPageKind.zhengfang,
                  LoginPageKind.webVpnGateway,
                },
              ) !=
              null;
      final loginPageReturned =
          statusCode == 200 && looksLikeZhengfangLoginHtml(html);

      if (redirectedToLogin ||
          loginPageReturned ||
          statusCode == 901 ||
          statusCode == 401) {
        if (_sessionRevision != revisionAtStart) {
          AppLogger.instance.auth(LogLevel.warn, '教务会话校验命中失效，但期间会话已变化，跳过登出');
          return null;
        }
        if (!revokeOnInvalid) {
          // guard 的无副作用探测：只报告失效，撤销留给 guard 的终态条件撤销。
          return false;
        }
        AppLogger.instance.auth(LogLevel.warn, '教务会话已失效，条件撤销');
        await revokeExpiredSessionIfCurrent(
          revision: revisionAtStart,
          account: accountAtStart,
          expectedEpoch: epochAtStart,
        );
        return false;
      }

      if (_sessionRevision != revisionAtStart) return null;
      if (statusCode == 200 && _looksLikeAuthenticatedAcademicHtml(html)) {
        return true;
      }
      if ((statusCode == 302 || statusCode == 303) &&
          _isAuthenticatedAcademicLocation(
            effectiveMode,
            Uri.parse(indexUrl).resolve(location).toString(),
          )) {
        return true;
      }
      return null;
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

  Future<bool?> ensureWebVpnGatewaySession({
    bool syncWebViewCookies = true,
    String? targetUrl,
  }) async {
    return (await ensureWebVpnGatewaySessionResult(
      syncWebViewCookies: syncWebViewCookies,
      targetUrl: targetUrl,
    )).ready;
  }

  /// 与 [ensureWebVpnGatewaySession] 相同，额外返回本次选中的连接模式，
  /// 避免调用方再读可能被并发请求改掉的全局 [ZhengfangAuth.mode]。
  Future<WebVpnGatewayEnsureResult> ensureWebVpnGatewaySessionResult({
    bool syncWebViewCookies = true,
    String? targetUrl,
    bool forceWebVpn = false,
  }) async {
    await DioClient.instance.ensureInitialized();
    // 绑定发起时 revision：网关探测期间切号/重登后，旧失效响应不得清掉新会话
    // 的 WebVPN 标记。
    final revisionAtStart = _sessionRevision;

    // FR-1: 不再无条件切换为 WebVPN。先探测连接模式：
    // - 直连可达 → 切回直连模式，无需 WebVPN 网关会话，直接返回 true。
    // - WebVPN 可达 → 切换 WebVPN 并建立网关会话。
    // - 两者均不可达 → 返回 null，网络异常不代表会话失效。
    //
    // [forceWebVpn] 跳过「直连可达即返回」：部分目标（如 libapp）直连探测能
    // 拿到 302，但 WebView 里直连会被服务端断开（net::ERR_CONNECTION_CLOSED），
    // 这类入口必须走 WebVPN 代理。
    var mode = await ConnectModeResolver.instance.resolve(targetUrl: targetUrl);
    if (!forceWebVpn) {
      if (mode == ZhengfangMode.direct) {
        if (_mode != ZhengfangMode.direct) {
          setMode(ZhengfangMode.direct);
        }
        return WebVpnGatewayEnsureResult(ready: true, selectedMode: mode);
      }
      if (mode != ZhengfangMode.webVpn) {
        AppLogger.instance.auth(
          LogLevel.warn,
          'WebVPN 网关会话不可用：直连与 WebVPN 均不可达',
        );
        return const WebVpnGatewayEnsureResult(ready: null);
      }
    }
    mode = ZhengfangMode.webVpn;
    // 全局模式只在网关会话确认建成后才切换：会话未激活 / 网络不确定 / 命中
    // 登录页时保持发起前的模式，免得并发的直连请求被带到未建成的 WebVPN。

    final unifiedAuthActive = await UnifiedAuthService.instance.validateSession(
      serviceUrl: ZhengfangAuth.webVpnGatewayServiceUrl,
      syncWebViewCookies: false,
    );
    if (unifiedAuthActive != true) {
      if (unifiedAuthActive == false) {
        _markWebVpnLoggedOutIfCurrent(revisionAtStart);
      }
      return WebVpnGatewayEnsureResult(
        ready: unifiedAuthActive,
        selectedMode: mode,
      );
    }

    try {
      final response = await _sendWithProxyFallback<String>(
        label: 'WebVPN 网关会话校验',
        mode: ZhengfangMode.webVpn,
        request: (dio, token) => dio.get<String>(
          ZhengfangAuth.webVpnGatewayLoginUrl,
          cancelToken: token,
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
        _markWebVpnLoggedOutIfCurrent(revisionAtStart);
        return WebVpnGatewayEnsureResult(ready: false, selectedMode: mode);
      }

      if (_sessionRevision == revisionAtStart) setMode(ZhengfangMode.webVpn);
      markWebVpnLoggedIn();
      if (syncWebViewCookies) {
        await syncWebVpnCookiesToWebView();
      }
      return WebVpnGatewayEnsureResult(ready: true, selectedMode: mode);
    } on DioException catch (e) {
      AppLogger.instance.auth(
        LogLevel.warn,
        'WebVPN 网关会话校验失败（网络异常）: ${e.type} ${e.message}',
      );
      return WebVpnGatewayEnsureResult(ready: null, selectedMode: mode);
    } catch (e) {
      AppLogger.instance.auth(LogLevel.warn, 'WebVPN 网关会话校验失败（未知异常）: $e');
      return WebVpnGatewayEnsureResult(ready: null, selectedMode: mode);
    }
  }

  /// 仅当会话 revision 仍是发起探测时的值时清除 WebVPN 标记，避免旧失效
  /// 响应清掉后来居上的新会话状态。
  void _markWebVpnLoggedOutIfCurrent(int revisionAtStart) {
    if (_sessionRevision != revisionAtStart) return;
    markWebVpnLoggedOut();
  }

  /// WebVPN 网关会话是否仍落在登录页：网关 / 统一认证 / 教务登录 URL、统一认证
  /// 登录页正文，或网关门户页（`/`、`/m/portal`、`/login`）。
  bool _looksLikeWebVpnAuthResponse(String url, String html) =>
      isWebVpnGatewayLoginBounce(url, html) || isWebVpnPortalUrl(url);
}
