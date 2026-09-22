part of 'zhengfang_auth.dart';

/// 教务验证码事务扩展。
///
/// 每个 challenge 持有独立内存 CookieJar + 冻结 Dio，从当前模式对应 jar 或
/// 当前 WebVPN 网关 cookie 快照初始化；登录表单与验证码图片都在该会话内
/// 取得，提交只使用同一会话。成功后条件提交（epoch 校验）才把 cookie 合并
/// 回共享 jar 并写 envelope。
extension ZhengfangAuthChallengeExtension on ZhengfangAuth {
  /// 准备一次教务验证码事务：隔离会话 → 登录页上下文 → 验证码 → arm。
  Future<CaptchaChallenge> prepareCaptchaChallenge({
    CancelToken? cancelToken,
  }) async {
    await DioClient.instance.ensureInitialized();
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    final mode = _mode;
    final revisionAtStart = _sessionRevision;
    // prepare 时固定持久 epoch：提交必须用它做条件提交。
    final expectedEpoch = await AuthSessionPersistence.instance.readEpoch(
      CredentialSessionDomain.academic,
    );
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    if (revisionAtStart != _sessionRevision || _mode != mode) {
      throw CaptchaException('登录上下文已过期，请重试');
    }

    final session = await IsolatedAuthSession.create(
      sourceJar: _cookieJarFor(mode),
      seedUris: _challengeSeedUris(mode),
      template: _dioFor(mode),
    );

    final context = await _buildChallengeContext(
      session,
      mode,
      expectedEpoch: expectedEpoch,
      cancelToken: cancelToken,
    );
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    if (revisionAtStart != _sessionRevision || _mode != mode) {
      throw CaptchaException('登录上下文已过期，请重试');
    }

    final bytes = await _fetchChallengeCaptcha(
      session,
      mode,
      cancelToken: cancelToken,
    );
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    if (revisionAtStart != _sessionRevision || _mode != mode) {
      throw CaptchaException('登录上下文已过期，请重试');
    }

    return _captchaChallenges.arm(
      domain: CaptchaChallengeDomain.zhengfang,
      accountRevision: _sessionRevision,
      bytes: bytes,
      context: context,
    );
  }

  /// 提交一次 challenge。单次提交；id 不匹配 / 过期 / 身份或模式变化一律
  /// 返回 [AuthFailureKind.staleOperation]。
  ///
  /// [recoveryTicket] 非空表示自动恢复路径：唯一提交点是
  /// [AuthOperationCoordinator.commitIsolatedSessionForTicket]，成功后把真实
  /// [SessionCommitResult] 放进 [LoginSuccess.receipt]。ticket 域/账号必须与
  /// 登录输入一致，否则拒绝。人工调用保持 null，走原有固定合并路径。
  Future<LoginResult> submitCaptchaChallenge({
    required String challengeId,
    required String username,
    required String password,
    required String captcha,
    CancelToken? cancelToken,
    AuthRecoveryTicket? recoveryTicket,
  }) async {
    final revisionAtStart = _sessionRevision;
    final attempt = _captchaChallenges.consume(
      challengeId,
      accountRevision: revisionAtStart,
    );
    if (attempt == null) {
      return LoginFailure(
        '验证码已失效，请刷新后重试',
        kind: AuthFailureKind.staleOperation,
      );
    }
    if (cancelToken?.isCancelled ?? false) {
      return LoginFailure('登录已取消', kind: AuthFailureKind.staleOperation);
    }
    if (recoveryTicket != null &&
        !_recoveryTicketMatchesInput(recoveryTicket, username)) {
      return LoginFailure(
        '登录状态已变化，请重试',
        kind: AuthFailureKind.staleOperation,
      );
    }
    return _performLogin(
      context: attempt.context,
      username: username,
      password: password,
      captcha: captcha,
      revisionAtStart: revisionAtStart,
      attemptGeneration: attempt.generation,
      cancelToken: cancelToken,
      recoveryTicket: recoveryTicket,
    );
  }

  /// 自动票据必须属于教务域且账号与本次登录输入一致；否则不得提交。
  bool _recoveryTicketMatchesInput(
    AuthRecoveryTicket ticket,
    String username,
  ) {
    if (ticket.domain != AuthRecoveryDomain.academic) return false;
    final trimmed = username.trim();
    return trimmed.isNotEmpty && ticket.account == trimmed;
  }

  /// 传 [challengeId] 时只失效该 id（不误清更新 widget 的新 challenge）。
  void invalidateChallenge({String? challengeId}) =>
      _captchaChallenges.invalidate(challengeId: challengeId);

  @visibleForTesting
  bool get hasActiveCaptchaChallenge => _captchaChallenges.hasChallenge;

  List<Uri> _challengeSeedUris(ZhengfangMode mode) {
    if (mode == ZhengfangMode.webVpn) {
      return [
        Uri.parse('${ZhengfangAuth._webVpnBase}/'),
        Uri.parse(
          '${ZhengfangAuth._webVpnBase}${ZhengfangAuth._webVpnLoginPath}',
        ),
        Uri.parse(
          '${ZhengfangAuth._webVpnBase}${ZhengfangAuth._webVpnJwglxtPrefix}/',
        ),
      ];
    }
    return [
      Uri.parse('${ZhengfangAuth._directOrigin}/'),
      Uri.parse(
        '${ZhengfangAuth._directOrigin}${ZhengfangAuth._directLoginPath}',
      ),
      Uri.parse('${ZhengfangAuth._directBase}/'),
    ];
  }

  Future<_ZhengfangChallengeContext> _buildChallengeContext(
    IsolatedAuthSession session,
    ZhengfangMode mode, {
    required int expectedEpoch,
    CancelToken? cancelToken,
  }) async {
    final loginPageUrl = _loginPageUrlFor(mode);
    final pageResp = await session.send<String>(
      label: '教务登录页上下文',
      cancelToken: cancelToken,
      request: (dio, token) => dio.get<String>(
        '${_baseUrlFor(mode)}/xtgl/login_slogin.html',
        cancelToken: token,
        options: Options(
          responseType: ResponseType.plain,
          headers: {'Referer': loginPageUrl},
        ),
      ),
    );

    final statusCode = pageResp.statusCode ?? 0;
    final location = pageResp.headers.value('location') ?? '';
    if (isZhengfangGatewayLoginUrl(location)) {
      AppLogger.instance.auth(LogLevel.warn, '检测到 WebVPN 登录页重定向，当前认证已过期');
      await markLoggedOut();
      throw CaptchaException('WebVPN 认证已过期，请重新登录');
    }

    if (isLoginSuccess(statusCode, location, '')) {
      // 访问登录入口却被重定向到首页：只证明**网络会话**有效，不证明学生号。
      // 因此不写 active、不通知；身份只有在已有可信 currentStudentId 时才成立。
      _contextIndicatesLoggedIn = true;
      _captchaChallenges.invalidate();
      AppLogger.instance.auth(LogLevel.info, '检测到教务已有有效会话（未凭跳转绑定身份）');
      return _ZhengfangChallengeContext(
        mode: mode,
        baseUrl: _baseUrlFor(mode),
        loginPageUrl: loginPageUrl,
        origin: _originFor(mode),
        csrfToken: '',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        session: session,
        expectedEpoch: expectedEpoch,
      );
    }

    final pageHtml = pageResp.data ?? '';
    final csrfToken = extractCsrfFromHtml(pageHtml);

    _contextIndicatesLoggedIn = false;
    if (csrfToken.isEmpty) {
      AppLogger.instance.auth(LogLevel.warn, 'CSRF Token 为空，可能连接异常');
    }
    return _ZhengfangChallengeContext(
      mode: mode,
      baseUrl: _baseUrlFor(mode),
      loginPageUrl: loginPageUrl,
      origin: _originFor(mode),
      csrfToken: csrfToken,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      session: session,
      expectedEpoch: expectedEpoch,
    );
  }

  Future<Uint8List> _fetchChallengeCaptcha(
    IsolatedAuthSession session,
    ZhengfangMode mode, {
    CancelToken? cancelToken,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final resp = await session.send<List<int>>(
      label: '教务验证码',
      cancelToken: cancelToken,
      request: (dio, token) => dio.get<List<int>>(
        '${_baseUrlFor(mode)}/kaptcha',
        queryParameters: {'time': ts},
        cancelToken: token,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Referer': _loginPageUrlFor(mode)},
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
      if (mode == ZhengfangMode.direct) {
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
      if (mode == ZhengfangMode.direct) {
        throw CaptchaException('无法连接到教务系统，请确保在校园网环境或已连接VPN');
      } else {
        throw CaptchaException('WebVPN 连接异常，请重试');
      }
    }

    AppLogger.instance.auth(LogLevel.info, '验证码获取成功, ${data.length} 字节');
    return data;
  }

  Future<LoginResult> _performLogin({
    required _ZhengfangChallengeContext context,
    required String username,
    required String password,
    required String captcha,
    required int revisionAtStart,
    required int? attemptGeneration,
    CancelToken? cancelToken,
    AuthRecoveryTicket? recoveryTicket,
  }) async {
    final mode = context.mode;
    try {
      if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
      if (_isLoginStale(revisionAtStart, attemptGeneration, mode)) {
        return LoginFailure(
          '登录状态已变化，请重试',
          kind: AuthFailureKind.staleOperation,
        );
      }

      if (context.csrfToken.isEmpty) {
        // 空 CSRF 只允许「已有可信身份且与输入账号一致」短路；绝不在没有
        // 真实 POST 的情况下把调用方输入的学号绑定到未知 session。
        if (_contextIndicatesLoggedIn &&
            username.isNotEmpty &&
            currentStudentId == username) {
          AppLogger.instance.auth(LogLevel.info, '检测到教务有效会话且身份一致，跳过登录请求');
          return LoginSuccess();
        }
        return LoginFailure(
          '初始化登录参数失败，请刷新验证码后重试',
          kind: AuthFailureKind.protocolChanged,
        );
      }

      final ts = context.timestampMs;
      final keyResp = await context.session.send<Map<String, dynamic>>(
        label: '教务登录公钥',
        cancelToken: cancelToken,
        request: (dio, token) => dio.get<Map<String, dynamic>>(
          '${context.baseUrl}/xtgl/login_getPublicKey.html',
          queryParameters: {'time': ts},
          cancelToken: token,
          options: Options(
            headers: {
              'Referer': context.loginPageUrl,
              'X-Requested-With': 'XMLHttpRequest',
            },
          ),
        ),
      );
      if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
      if (_isLoginStale(revisionAtStart, attemptGeneration, mode)) {
        return LoginFailure(
          '登录状态已变化，请重试',
          kind: AuthFailureKind.staleOperation,
        );
      }

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
      final loginResp = await context.session.send<String>(
        label: '教务登录',
        cancelToken: cancelToken,
        request: (dio, token) => dio.post<String>(
          '${context.baseUrl}/xtgl/login_slogin.html',
          queryParameters: {'time': ts},
          cancelToken: token,
          data: {
            'csrftoken': context.csrfToken,
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
            headers: {
              'Referer': context.loginPageUrl,
              'Origin': context.origin,
            },
          ),
        ),
      );

      if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
      if (_isLoginStale(revisionAtStart, attemptGeneration, mode)) {
        return LoginFailure(
          '登录状态已变化，请重试',
          kind: AuthFailureKind.staleOperation,
        );
      }

      final location = loginResp.headers.value('location') ?? '';
      final html = loginResp.data ?? '';
      if (isZhengfangGatewayLoginUrl(location)) {
        AppLogger.instance.auth(LogLevel.warn, '教务系统登录被重定向到 WebVPN 登录页');
        return LoginFailure('WebVPN 认证已过期，请重新登录');
      }
      if (isLoginSuccess(loginResp.statusCode, location, html)) {
        // 条件提交：epoch 校验通过才合并 cookie + 写 envelope；使用 prepare 时
        // 固定的 context.expectedEpoch，绝不重新读取当前 epoch。
        // 自动恢复路径（recoveryTicket != null）唯一走 typed ticket commit。
        final result = await _commitChallengeSession(
          context,
          username,
          context.expectedEpoch,
          recoveryTicket: recoveryTicket,
        );
        if (result == null) {
          // 别的提交（logout 或更新的登录）已胜出：绝不全局 revoke。
          return LoginFailure(
            '登录状态已变化，请重试',
            kind: AuthFailureKind.staleOperation,
          );
        }
        if (_isLoginStale(revisionAtStart, attemptGeneration, mode)) {
          // 本提交已写入但已过期：只在 envelope 仍是本次提交时条件撤销。
          await AuthSessionPersistence.instance.revokeIfCurrent(
            CredentialSessionDomain.academic,
            account: result.account,
            epoch: result.epoch,
          );
          return LoginFailure(
            '登录状态已变化，请重试',
            kind: AuthFailureKind.staleOperation,
          );
        }
        _applySessionIdentity(active: true, studentId: username);

        AppLogger.instance.auth(
          LogLevel.info,
          '教务系统登录成功 [${mode == ZhengfangMode.direct ? "直连" : "WebVPN"}]',
        );
        _notifyAuthListeners();
        return LoginSuccess(receipt: result);
      }

      final msg = extractLoginFailureMessage(html);
      final kind = AuthFailureClassifier.classify(html: html);

      AppLogger.instance.auth(LogLevel.warn, '教务系统登录失败: $msg');
      return LoginFailure(msg, kind: kind);
    } on DioException catch (e) {
      if (_isLoginStale(revisionAtStart, attemptGeneration, mode)) {
        return LoginFailure(
          '登录状态已变化，请重试',
          kind: AuthFailureKind.staleOperation,
        );
      }
      AppLogger.instance.auth(
        LogLevel.error,
        '教务系统登录网络异常: ${e.type} ${e.message}',
      );
      return LoginFailure(
        '网络错误：${e.message}',
        kind: AuthFailureClassifier.fromTransport(e),
      );
    } catch (e) {
      return LoginFailure('登录异常：$e');
    }
  }

  Future<SessionCommitResult?> _commitChallengeSession(
    _ZhengfangChallengeContext context,
    String account,
    int expectedEpoch, {
    AuthRecoveryTicket? recoveryTicket,
  }) {
    if (recoveryTicket != null) {
      return AuthOperationCoordinator.instance.commitIsolatedSessionForTicket(
        recoveryTicket,
        expectedSessionEpoch: expectedEpoch,
        sessionDomain: CredentialSessionDomain.academic,
        session: context.session,
        target: _cookieJarFor(context.mode),
      );
    }
    return AuthSessionPersistence.instance.commitWithIsolatedSession(
      CredentialSessionDomain.academic,
      account: account,
      expectedEpoch: expectedEpoch,
      session: context.session,
      target: _cookieJarFor(context.mode),
    );
  }

  bool _isLoginStale(
    int revisionAtStart,
    int? attemptGeneration,
    ZhengfangMode mode,
  ) {
    if (revisionAtStart != _sessionRevision) return true;
    if (_mode != mode) return true;
    if (attemptGeneration != null &&
        !_captchaChallenges.isAttemptCurrent(attemptGeneration)) {
      return true;
    }
    return false;
  }
}
