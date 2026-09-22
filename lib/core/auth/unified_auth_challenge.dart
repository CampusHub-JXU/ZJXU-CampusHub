part of 'unified_auth.dart';

/// 统一认证验证码事务（challenge）扩展。
///
/// 每个 challenge 持有**独立内存 CookieJar + 冻结 Dio**（[IsolatedAuthSession]），
/// 从当前可信统一认证 jar 快照初始化；prepare 的登录表单与验证码图片都在
/// 该会话内取得，submit 只使用同一会话，因此并发 prepare 不会串扰
/// （context_A + cookie_B + image_B）。
///
/// 兼容包装：`fetchCaptcha` 仍返回图片字节并 arm 当前 challenge；
/// 无 id 的 `login` 只消费它所引用的当前 challenge，**绝不重新初始化上下文**。
extension UnifiedAuthChallengeExtension on UnifiedAuthService {
  /// 准备一次验证码事务：隔离会话 → 登录表单 → 验证码图片 → arm。
  Future<CaptchaChallenge> prepareCaptchaChallenge({
    String serviceUrl = UnifiedAuthService.defaultServiceUrl,
    CancelToken? cancelToken,
  }) async {
    await DioClient.instance.ensureInitialized();
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    final revisionAtStart = sessionRevision;
    // prepare 时固定持久 epoch：提交必须用它做条件提交，跨 isolate 撤销后
    // 即使内存 revision 未变也会被拒绝。
    final expectedEpoch = await AuthSessionPersistence.instance.readEpoch(
      CredentialSessionDomain.unified,
    );
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    if (revisionAtStart != sessionRevision) {
      throw UnifiedAuthIncompleteSessionException('统一认证登录上下文已过期，请重试');
    }

    if (!isLoggedIn) {
      // 保持旧语义：无可信身份时先清 CAS host Cookie，避免孤儿身份被带入。
      await _clearCasOriginCookies();
      if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
      if (revisionAtStart != sessionRevision) {
        throw UnifiedAuthIncompleteSessionException('统一认证登录上下文已过期，请重试');
      }
    }

    final session = await IsolatedAuthSession.create(
      sourceJar: _cookieJar,
      seedUris: [
        Uri.parse('${UnifiedAuthService._newcaOrigin}/cas/login'),
        Uri.parse('${UnifiedAuthService._newcaOrigin}/'),
      ],
      template: _dio,
      fallbackAdapter: debugProxyFallbackAdapter,
    );

    final context = await _buildChallengeContext(
      session,
      serviceUrl,
      expectedEpoch: expectedEpoch,
      cancelToken: cancelToken,
    );
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    if (revisionAtStart != sessionRevision) {
      throw UnifiedAuthIncompleteSessionException('统一认证登录上下文已过期，请重试');
    }

    final bytes = await _fetchChallengeCaptcha(
      session,
      serviceUrl,
      cancelToken: cancelToken,
    );
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    if (revisionAtStart != sessionRevision) {
      throw UnifiedAuthIncompleteSessionException('统一认证登录上下文已过期，请重试');
    }

    return _captchaChallenges.arm(
      domain: CaptchaChallengeDomain.unifiedAuth,
      accountRevision: sessionRevision,
      bytes: bytes,
      context: context,
      serviceUrl: serviceUrl,
    );
  }

  /// 提交一次 challenge。只允许当前 challenge 单次提交；id 不匹配 / 过期 /
  /// 身份修订变化一律返回 [AuthFailureKind.staleOperation]。
  ///
  /// [recoveryTicket] 非空表示这是**自动恢复路径**：唯一提交点是
  /// [AuthOperationCoordinator.commitIsolatedSessionForTicket]（typed ticket
  /// commit），成功后把真实 [SessionCommitResult] 放进
  /// [UnifiedAuthLoginSuccess.receipt]；ticket 所属域/账号必须与本次登录输入
  /// 一致，否则直接拒绝。人工调用保持 null，走原有固定合并路径。
  ///
  /// [syncWebViewCookies] 为 false 时禁止 WebView cookie 同步（自动路径显式
  /// 关闭）；默认 true 保留人工旧行为。
  Future<UnifiedAuthLoginResult> submitCaptchaChallenge({
    required String challengeId,
    required String username,
    required String password,
    required String captcha,
    CancelToken? cancelToken,
    AuthRecoveryTicket? recoveryTicket,
    bool syncWebViewCookies = true,
  }) async {
    final revisionAtStart = sessionRevision;
    final attempt = _captchaChallenges.consume(
      challengeId,
      accountRevision: revisionAtStart,
    );
    if (attempt == null) {
      return UnifiedAuthLoginFailure(
        '验证码已失效，请刷新后重试',
        kind: AuthFailureKind.staleOperation,
      );
    }
    if (cancelToken?.isCancelled ?? false) {
      return UnifiedAuthLoginFailure(
        '登录已取消',
        kind: AuthFailureKind.staleOperation,
      );
    }
    if (recoveryTicket != null &&
        !_recoveryTicketMatchesInput(recoveryTicket, username)) {
      return UnifiedAuthLoginFailure(
        '登录状态已变化，请重试',
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
      recoveryTicket: recoveryTicket,
      syncWebViewCookies: syncWebViewCookies,
    );
  }

  /// 自动票据必须属于 CAS 域且账号与本次登录输入一致；否则不得提交。
  bool _recoveryTicketMatchesInput(
    AuthRecoveryTicket ticket,
    String username,
  ) {
    if (ticket.domain != AuthRecoveryDomain.cas) return false;
    final trimmed = username.trim();
    return trimmed.isNotEmpty && ticket.account == trimmed;
  }

  /// 使 challenge 失效。
  ///
  /// 传 [challengeId] 时只失效该 id（不误清更新 widget 已建立的 challenge）；
  /// 不传则失效当前 challenge。
  void invalidateChallenge({String? challengeId}) =>
      _captchaChallenges.invalidate(challengeId: challengeId);

  @visibleForTesting
  bool get hasActiveCaptchaChallenge => _captchaChallenges.hasChallenge;

  Future<_UnifiedAuthChallengeContext> _buildChallengeContext(
    IsolatedAuthSession session,
    String serviceUrl, {
    required int expectedEpoch,
    CancelToken? cancelToken,
  }) async {
    if (isLoggedIn) {
      return _UnifiedAuthChallengeContext(
        serviceUrl: serviceUrl,
        lt: '',
        execution: '',
        actionUri: _buildLoginUri(serviceUrl),
        session: session,
        expectedEpoch: expectedEpoch,
      );
    }

    final loginUri = _buildLoginUri(serviceUrl);
    final response = await session.send<String>(
      label: '统一认证登录上下文',
      cancelToken: cancelToken,
      requestTimeout: UnifiedAuthService._requestTimeout,
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

    final statusCode = response.statusCode ?? 0;
    final location = response.headers.value('location') ?? '';
    if ((statusCode == 302 || statusCode == 303) && location.isNotEmpty) {
      final lowerLocation = location.toLowerCase();
      if (!lowerLocation.contains('/cas/login')) {
        AppLogger.instance.auth(LogLevel.warn, '统一认证已有未知身份 session，拒绝写成已登录');
        throw UnifiedAuthIncompleteSessionException('统一认证会话身份未知，请刷新后重试');
      }
      final redirectUrl = _resolveUri(loginUri, location).toString();
      final casResp = await session.send<String>(
        label: '统一认证登录页重定向',
        cancelToken: cancelToken,
        requestTimeout: UnifiedAuthService._requestTimeout,
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
      return _UnifiedAuthChallengeContext(
        serviceUrl: serviceUrl,
        lt: _extractHiddenField(html, 'lt'),
        execution: _extractHiddenField(html, 'execution'),
        actionUri: _resolveUri(loginUri, _extractFormAction(html)),
        session: session,
        expectedEpoch: expectedEpoch,
      );
    }

    final html = response.data ?? '';
    return _UnifiedAuthChallengeContext(
      serviceUrl: serviceUrl,
      lt: _extractHiddenField(html, 'lt'),
      execution: _extractHiddenField(html, 'execution'),
      actionUri: _resolveUri(loginUri, _extractFormAction(html)),
      session: session,
      expectedEpoch: expectedEpoch,
    );
  }

  Future<Uint8List> _fetchChallengeCaptcha(
    IsolatedAuthSession session,
    String serviceUrl, {
    CancelToken? cancelToken,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final referer = _buildLoginUri(serviceUrl).toString();
    final captchaUri = Uri.parse(
      '${UnifiedAuthService._newcaOrigin}/cas/captcha.html?t=$timestamp',
    );
    final resp = await session.send<List<int>>(
      label: '统一认证验证码',
      cancelToken: cancelToken,
      requestTimeout: UnifiedAuthService._requestTimeout,
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

  Future<UnifiedAuthLoginResult> _submitUnifiedLogin({
    required _UnifiedAuthChallengeContext context,
    required String username,
    required String password,
    required String captcha,
    required int revisionAtStart,
    required int? attemptGeneration,
    CancelToken? cancelToken,
    AuthRecoveryTicket? recoveryTicket,
    bool syncWebViewCookies = true,
  }) async {
    try {
      if (context.lt.isEmpty || context.execution.isEmpty) {
        // 空上下文只允许已知身份同账号短路，不得把输入学号绑到旧 session。
        if (isLoggedIn && currentAccount == username) {
          AppLogger.instance.auth(LogLevel.info, '统一认证已有有效 session，跳过登录');
          return UnifiedAuthLoginSuccess();
        }
        AppLogger.instance.auth(LogLevel.warn, '统一认证初始化上下文缺失');
        return UnifiedAuthLoginFailure(
          '统一认证初始化失败，请刷新验证码后重试',
          kind: AuthFailureKind.protocolChanged,
        );
      }

      final encryptedPassword = AuthCrypto.instance.encryptPassword(password);
      final referer = _buildLoginUri(context.serviceUrl).toString();
      final response = await context.session.send<String>(
        label: '统一认证登录',
        cancelToken: cancelToken,
        requestTimeout: UnifiedAuthService._requestTimeout,
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
            headers: {
              'Referer': referer,
              'Origin': UnifiedAuthService._newcaOrigin,
            },
          ),
        ),
      );

      if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
      if (_isAttemptStale(revisionAtStart, attemptGeneration)) {
        return UnifiedAuthLoginFailure(
          '登录状态已变化，请重试',
          kind: AuthFailureKind.staleOperation,
        );
      }

      final location = response.headers.value('location') ?? '';
      final html = response.data ?? '';
      if (isLoginSuccess(response.statusCode, location, html)) {
        await _followChallengeRedirectChain(
          context.session,
          context.actionUri,
          location,
          cancelToken: cancelToken,
        );
        if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
        if (_isAttemptStale(revisionAtStart, attemptGeneration)) {
          return UnifiedAuthLoginFailure(
            '登录状态已变化，请重试',
            kind: AuthFailureKind.staleOperation,
          );
        }

        // 条件提交：epoch 校验通过才把隔离会话 cookie 合并回共享 jar 并写
        // envelope；epoch 已变（logout/换号/跨 isolate 撤销）则整体拒绝。
        // 使用 prepare 时固定的 context.expectedEpoch，绝不重新读取当前 epoch。
        //
        // 自动恢复路径（recoveryTicket != null）**唯一**走 typed ticket commit：
        // 它在恢复状态锁内重新校验 ticket（opt-in/撤销/epoch/凭据/人工租约），
        // 是唯一登录提交点，不再有第二次 metadata 写入。
        final result = recoveryTicket == null
            ? await AuthSessionPersistence.instance.commitWithIsolatedSession(
                CredentialSessionDomain.unified,
                account: username,
                expectedEpoch: context.expectedEpoch,
                session: context.session,
                target: _cookieJar,
              )
            : await AuthOperationCoordinator.instance
                  .commitIsolatedSessionForTicket(
                    recoveryTicket,
                    expectedSessionEpoch: context.expectedEpoch,
                    sessionDomain: CredentialSessionDomain.unified,
                    session: context.session,
                    target: _cookieJar,
                  );
        if (result == null) {
          // 别的提交（logout 或更新的登录）已胜出：绝不全局 revoke，避免误杀。
          return UnifiedAuthLoginFailure(
            '登录状态已变化，请重试',
            kind: AuthFailureKind.staleOperation,
          );
        }
        if (_isAttemptStale(revisionAtStart, attemptGeneration)) {
          // 本提交已写入但已过期：只在 envelope 仍是本次提交时条件撤销。
          await AuthSessionPersistence.instance.revokeIfCurrent(
            CredentialSessionDomain.unified,
            account: result.account,
            epoch: result.epoch,
          );
          return UnifiedAuthLoginFailure(
            '登录状态已变化，请重试',
            kind: AuthFailureKind.staleOperation,
          );
        }

        if (syncWebViewCookies) {
          unawaited(_syncCookiesToWebViewSafely());
        }
        _applySessionIdentity(active: true, account: username);
        _notifyLoginSuccess();
        AppLogger.instance.auth(
          LogLevel.info,
          syncWebViewCookies ? '统一认证登录成功，已同步 WebView Cookie' : '统一认证登录成功',
        );
        return UnifiedAuthLoginSuccess(receipt: result);
      }

      final msg = extractLoginFailureMessage(html);
      final kind = AuthFailureClassifier.classify(html: html);
      AppLogger.instance.auth(LogLevel.warn, '统一认证登录失败: $msg');
      return UnifiedAuthLoginFailure(msg, kind: kind);
    } on UnifiedAuthIncompleteSessionException catch (error) {
      AppLogger.instance.auth(LogLevel.warn, error.message);
      return UnifiedAuthLoginFailure(
        error.message,
        kind: AuthFailureKind.protocolChanged,
      );
    } on DioException catch (error) {
      if (_isAttemptStale(revisionAtStart, attemptGeneration)) {
        return UnifiedAuthLoginFailure(
          '登录状态已变化，请重试',
          kind: AuthFailureKind.staleOperation,
        );
      }
      AppLogger.instance.auth(
        LogLevel.error,
        '统一认证登录网络异常: ${error.type} ${error.message}',
      );
      return UnifiedAuthLoginFailure(
        '统一认证网络异常：${error.message}',
        kind: AuthFailureClassifier.fromTransport(error),
      );
    } catch (error) {
      return UnifiedAuthLoginFailure('统一认证登录失败：$error');
    }
  }

  Future<void> _followChallengeRedirectChain(
    IsolatedAuthSession session,
    Uri baseUri,
    String location, {
    CancelToken? cancelToken,
  }) async {
    var nextUri = _resolveUri(baseUri, location);
    for (var i = 0; i < 8; i++) {
      final nextUrl = nextUri.toString();
      if (isUnifiedAuthLoginEntryUrl(nextUrl) && !urlHasCasTicket(nextUrl)) {
        AppLogger.instance.auth(LogLevel.debug, '统一认证重定向链: 回到 CAS 登录入口，停止跟随');
        return;
      }
      final response = await session.send<String>(
        label: '统一认证重定向链',
        cancelToken: cancelToken,
        requestTimeout: UnifiedAuthService._requestTimeout,
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

  bool _isAttemptStale(int revisionAtStart, int? attemptGeneration) {
    if (revisionAtStart != sessionRevision) return true;
    if (attemptGeneration != null &&
        !_captchaChallenges.isAttemptCurrent(attemptGeneration)) {
      return true;
    }
    return false;
  }
}
