import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/auth/auth_failure.dart';
import '../../core/auth/auth_operation_coordinator.dart';
import '../../core/auth/auth_recovery_state_store.dart';
import '../../core/auth/captcha_challenge.dart';
import '../../core/auth/credential_store.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/network/cancel_token_x.dart';
import 'app_banner.dart';
import 'login_parts.dart';

enum UnifiedAuthMode { direct }

typedef LoginCredentialLoader = Future<(String, String)?> Function();
typedef LoginCredentialSaver = Future<void> Function(
  String username,
  String password,
);
typedef LoginCredentialClearer = Future<void> Function();

/// 「记住账号并自动登录」勾选后启用该域自动恢复（可注入，默认走协调器）。
typedef LoginAutoLoginEnabler = Future<AuthRecoveryEnableResult> Function(
  String account,
);

/// 登录成功且自动恢复已启用时记录一次成功（可注入，默认走协调器）。
typedef LoginAutoLoginSuccessRecorder = Future<void> Function();

/// 未勾选时关闭该域自动恢复（可注入，默认走协调器）。
typedef LoginAutoLoginDisabler = Future<void> Function();

typedef LoginSessionPreflight = Future<bool> Function();
typedef LoginCaptchaLoader = Future<Uint8List> Function();
typedef LoginSubmitHandler = Future<String?> Function(
  String username,
  String password,
  String captcha,
);
typedef UnifiedAuthChallengeLoader = Future<CaptchaChallenge> Function({
  CancelToken? cancelToken,
});
typedef UnifiedAuthChallengeSubmitHandler =
    Future<UnifiedAuthLoginResult> Function({
      required String challengeId,
      required String username,
      required String password,
      required String captcha,
      CancelToken? cancelToken,
    });
typedef UnifiedAuthChallengeInvalidator = void Function(String challengeId);

class UnifiedAuthLoginWidget extends StatefulWidget {
  const UnifiedAuthLoginWidget({
    super.key,
    required this.onLoginSuccess,
    this.serviceUrl = UnifiedAuthService.defaultServiceUrl,
    this.title = '登录统一认证',
    this.description = '账号为校园一卡通号',
    this.loadSavedCredentials,
    this.saveCredentials,
    this.clearCredentials,
    this.enableAutoLogin,
    this.recordAutoLoginSuccess,
    this.disableAutoLogin,
    this.sessionPreflight,
    this.captchaLoader,
    this.loginHandler,
    this.challengeLoader,
    this.challengeSubmitter,
    this.challengeInvalidator,
    this.showHeader = true,
    this.padding = const EdgeInsets.all(24),
  });

  final VoidCallback onLoginSuccess;
  final String serviceUrl;
  final String title;
  final String description;
  final LoginCredentialLoader? loadSavedCredentials;
  final LoginCredentialSaver? saveCredentials;
  final LoginCredentialClearer? clearCredentials;
  final LoginAutoLoginEnabler? enableAutoLogin;
  final LoginAutoLoginSuccessRecorder? recordAutoLoginSuccess;
  final LoginAutoLoginDisabler? disableAutoLogin;
  final LoginSessionPreflight? sessionPreflight;
  final LoginCaptchaLoader? captchaLoader;
  final LoginSubmitHandler? loginHandler;
  final UnifiedAuthChallengeLoader? challengeLoader;
  final UnifiedAuthChallengeSubmitHandler? challengeSubmitter;
  final UnifiedAuthChallengeInvalidator? challengeInvalidator;
  final bool showHeader;
  final EdgeInsetsGeometry padding;

  @override
  State<UnifiedAuthLoginWidget> createState() => _UnifiedAuthLoginWidgetState();
}

class _UnifiedAuthLoginWidgetState extends State<UnifiedAuthLoginWidget> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _captchaCtrl = TextEditingController();
  final _usernameFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  final _captchaFocusNode = FocusNode();

  Uint8List? _captchaBytes;
  String? _challengeId;
  int _captchaRequestId = 0;
  int _syntheticChallengeCounter = 0;
  bool _loading = false;
  bool _captchaLoading = false;
  CancelToken? _captchaCancelToken;
  CancelToken? _loginCancelToken;
  bool _obscurePassword = true;

  /// 「记住账号并自动登录」勾选状态：仅本次会话有效，重新打开默认勾选。
  bool _rememberAccount = true;
  String? _error;

  static const _proxyHint = '请求超时，请切换网络后重试；如使用代理或 VPN，请检查其设置';

  @override
  void initState() {
    super.initState();
    _beginManualLogin();
  }

  Future<void> Function()? _releaseManualAttempt;

  Future<void> _beginManualLogin() async {
    final release = AuthOperationCoordinator.instance.acquireManualAttempt(
      AuthRecoveryDomain.cas,
    );
    if (!mounted) {
      await release();
      return;
    }
    _releaseManualAttempt = release;
    await _refreshCaptcha(prepare: true);
  }

  void _invalidateChallenge(String? challengeId) {
    if (challengeId == null) return;
    final invalidator = widget.challengeInvalidator;
    if (invalidator != null) {
      invalidator(challengeId);
      return;
    }
    UnifiedAuthService.instance.invalidateChallenge(challengeId: challengeId);
  }

  Future<bool> _preparePrimaryLoginMode(CancelToken token) async {
    if (widget.sessionPreflight != null) {
      final hasActiveSession = await widget.sessionPreflight!.call();
      token.throwIfCancelled();
      if (!mounted || hasActiveSession) {
        return hasActiveSession;
      }
    } else if (UnifiedAuthService.instance.isLoggedIn) {
      return true;
    }

    if (widget.challengeLoader != null || widget.captchaLoader != null) {
      return false;
    }
    if (widget.loginHandler != null || widget.challengeSubmitter != null) {
      return false;
    }

    return UnifiedAuthService.instance.prepareLogin(
      serviceUrl: widget.serviceUrl,
      cancelToken: token,
    );
  }

  Future<void> _loadSaved(CancelToken token) async {
    final credentials =
        await widget.loadSavedCredentials?.call() ??
        await CredentialStore.instance.loadUnifiedAuthCredentials();
    if (!mounted || token.isCancelled) return;
    if (credentials != null) {
      _usernameCtrl.text = credentials.$1;
      _passwordCtrl.text = credentials.$2;
    }
  }

  Future<void> _refreshCaptcha({
    bool preserveError = false,
    bool prepare = false,
  }) async {
    if (_captchaLoading || _loading) return;
    final previousError = preserveError ? _error : null;
    final requestId = ++_captchaRequestId;
    final token = CancelToken();
    _captchaCancelToken?.cancel('New captcha requested');
    _captchaCancelToken = token;

    final oldChallengeId = _challengeId;
    _invalidateChallenge(oldChallengeId);

    // 真实 challenge 一旦由 service 建立就记录 id：若结果最终被丢弃
    //（超时 / 刷新 / 切阶段 / 销毁 / 解码失败），必须按 id 失效，避免 service
    // 侧遗留活动 challenge。synthetic 注入分支不产生 service challenge。
    String? armedChallengeId;

    setState(() {
      _captchaLoading = true;
      _captchaBytes = null;
      _challengeId = null;
      _error = previousError;
    });
    _captchaCtrl.clear();
    try {
      final challengeResult =
          await Future.any<({Uint8List bytes, String id})?>([
            (() async {
              if (prepare) {
                await _loadSaved(token);
                token.throwIfCancelled();
                if (await _preparePrimaryLoginMode(token)) return null;
              }
              token.throwIfCancelled();
              if (widget.challengeLoader != null) {
                final ch = await widget.challengeLoader!(cancelToken: token);
                if (!mounted ||
                    requestId != _captchaRequestId ||
                    token.isCancelled) {
                  _invalidateChallenge(ch.id);
                } else {
                  armedChallengeId = ch.id;
                }
                return (bytes: ch.bytes, id: ch.id);
              }
              if (widget.captchaLoader != null) {
                final bytes = await widget.captchaLoader!();
                return (
                  bytes: bytes,
                  id: 'synthetic-challenge-${++_syntheticChallengeCounter}',
                );
              }
              final ch = await UnifiedAuthService.instance
                  .prepareCaptchaChallenge(
                    serviceUrl: widget.serviceUrl,
                    cancelToken: token,
                  );
              if (!mounted ||
                  requestId != _captchaRequestId ||
                  token.isCancelled) {
                _invalidateChallenge(ch.id);
              } else {
                armedChallengeId = ch.id;
              }
              return (bytes: ch.bytes, id: ch.id);
            })(),
            token.whenCancel.then((error) => throw error),
          ]).timeout(
            const Duration(seconds: 20),
            onTimeout: () {
              token.cancel('Captcha preparation timed out');
              throw TimeoutException('Captcha preparation timed out');
            },
          );
      if (!mounted || requestId != _captchaRequestId || token.isCancelled) {
        return;
      }
      if (challengeResult == null) {
        widget.onLoginSuccess();
        return;
      }
      final codec = await ui.instantiateImageCodec(challengeResult.bytes);
      codec.dispose();
      if (!mounted || requestId != _captchaRequestId || token.isCancelled) {
        return;
      }
      setState(() {
        _captchaBytes = challengeResult.bytes;
        _challengeId = challengeResult.id;
        _error = previousError;
      });
      armedChallengeId = null;
    } on UnifiedAuthCaptchaException catch (error) {
      if (!mounted || requestId != _captchaRequestId) return;
      setState(() {
        _captchaBytes = null;
        _challengeId = null;
        _error = error.message;
      });
    } on DioException catch (e) {
      if (!mounted || requestId != _captchaRequestId) return;
      if (e.type == DioExceptionType.cancel && e.error is! TimeoutException) {
        return;
      }
      setState(() {
        _captchaBytes = null;
        _challengeId = null;
        _error = _friendlyNetworkMessage(e, fallback: '验证码加载失败，请点击重试');
      });
    } catch (error) {
      if (!mounted || requestId != _captchaRequestId) return;
      setState(() {
        _captchaBytes = null;
        _challengeId = null;
        _error = _friendlyNetworkMessage(error, fallback: '验证码加载失败，请点击重试');
      });
    } finally {
      if (armedChallengeId != null) {
        _invalidateChallenge(armedChallengeId);
      }
      token.cancel('Captcha loading finished');
      if (mounted && requestId == _captchaRequestId) {
        setState(() => _captchaLoading = false);
      }
    }
  }

  String _friendlyNetworkMessage(Object error, {required String fallback}) {
    if (error is TimeoutException) return _proxyHint;
    final text = error.toString().toLowerCase();
    if (text.contains('handshakeexception') ||
        text.contains('connection terminated during handshake')) {
      return '无法连接统一认证，请检查系统代理、VPN 或网络证书环境后重试';
    }
    if (error is DioException) {
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        return _proxyHint;
      }
      if (error.type == DioExceptionType.connectionError) {
        return '无法连接统一认证，请检查网络或系统代理设置';
      }
      return '网络错误：${error.message ?? "请稍后重试"}';
    }
    return fallback;
  }

  Future<void> _login() async {
    if (_loading ||
        _captchaLoading ||
        _captchaBytes == null ||
        _challengeId == null) {
      return;
    }
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    final captcha = _captchaCtrl.text.trim();
    if (username.isEmpty || password.isEmpty || captcha.isEmpty) {
      setState(() => _error = '请填写账号、密码和验证码');
      return;
    }

    final challengeId = _challengeId!;
    final token = CancelToken();
    _loginCancelToken = token;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      if (widget.challengeSubmitter != null) {
        final result = await widget.challengeSubmitter!(
          challengeId: challengeId,
          username: username,
          password: password,
          captcha: captcha,
          cancelToken: token,
        );
        if (!mounted || token.isCancelled) return;
        switch (result) {
          case UnifiedAuthLoginSuccess():
            await _applyAutoLoginPreference(
              username: username,
              password: password,
            );
            if (!mounted) return;
            widget.onLoginSuccess();
          case UnifiedAuthLoginFailure(:final message, :final kind):
            final displayMessage = kind == AuthFailureKind.staleOperation
                ? (message.isNotEmpty ? message : '验证码已失效，请刷新后重试')
                : (message.isNotEmpty ? message : '登录失败，请重试');
            setState(() {
              _loading = false;
              _error = displayMessage;
            });
            _captchaCtrl.clear();
            await _refreshCaptcha(preserveError: true);
        }
        return;
      }

      if (widget.loginHandler != null) {
        final message = await widget.loginHandler!(username, password, captcha);
        if (!mounted || token.isCancelled) return;
        if (message == null) {
          await _applyAutoLoginPreference(
            username: username,
            password: password,
          );
          if (!mounted) return;
          widget.onLoginSuccess();
          return;
        }

        setState(() {
          _loading = false;
          _error = message;
        });
        _captchaCtrl.clear();
        await _refreshCaptcha(preserveError: true);
        return;
      }

      final result = await UnifiedAuthService.instance.submitCaptchaChallenge(
        challengeId: challengeId,
        username: username,
        password: password,
        captcha: captcha,
        cancelToken: token,
      );
      if (!mounted || token.isCancelled) return;

      switch (result) {
        case UnifiedAuthLoginSuccess():
          await _applyAutoLoginPreference(
            username: username,
            password: password,
          );
          if (!mounted) return;
          widget.onLoginSuccess();
        case UnifiedAuthLoginFailure(:final message, :final kind):
          final displayMessage = kind == AuthFailureKind.staleOperation
              ? (message.isNotEmpty ? message : '验证码已失效，请刷新后重试')
              : (message.isNotEmpty ? message : '登录失败，请重试');
          setState(() {
            _loading = false;
            _error = displayMessage;
          });
          _captchaCtrl.clear();
          await _refreshCaptcha(preserveError: true);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _friendlyNetworkMessage(error, fallback: '登录未完成，请重试');
      });
    } finally {
      token.cancel('Login finished');
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 登录成功后按勾选状态分叉：勾选则保存凭据并启用自动恢复，未勾选则清除
  /// 凭据并关闭自动恢复。**任何自动恢复侧的失败都不得影响登录成功本身**，
  /// 只记录日志（不打印凭据）。
  Future<void> _applyAutoLoginPreference({
    required String username,
    required String password,
  }) async {
    if (_rememberAccount) {
      try {
        await (widget.saveCredentials?.call(username, password) ??
            CredentialStore.instance.saveUnifiedAuthCredentials(
              username,
              password,
            ));
      } catch (error, stackTrace) {
        _logAutoLoginFailure('保存统一认证凭据失败', error, stackTrace);
      }

      final AuthRecoveryEnableResult enableResult;
      try {
        enableResult =
            await (widget.enableAutoLogin?.call(username) ??
                AuthOperationCoordinator.instance.enableAutomaticRecovery(
                  AuthRecoveryDomain.cas,
                  expectedAccount: username,
                ));
      } catch (error, stackTrace) {
        _logAutoLoginFailure('启用统一认证自动登录失败', error, stackTrace);
        return;
      }
      if (enableResult != AuthRecoveryEnableResult.enabled) {
        AppLogger.instance.auth(
          LogLevel.warn,
          '统一认证自动登录未启用（${enableResult.name}），登录成功不受影响',
        );
        return;
      }

      try {
        await (widget.recordAutoLoginSuccess?.call() ??
            AuthOperationCoordinator.instance.recordSuccess(
              AuthRecoveryDomain.cas,
            ));
      } catch (error, stackTrace) {
        _logAutoLoginFailure('记录统一认证登录成功失败', error, stackTrace);
      }
      return;
    }

    try {
      await (widget.clearCredentials?.call() ??
          CredentialStore.instance.clearUnifiedAuthCredentials());
    } catch (error, stackTrace) {
      _logAutoLoginFailure('清除统一认证凭据失败', error, stackTrace);
    }
    try {
      await (widget.disableAutoLogin?.call() ??
          AuthOperationCoordinator.instance.disableAutomaticRecovery(
            AuthRecoveryDomain.cas,
          ));
    } catch (error, stackTrace) {
      _logAutoLoginFailure('关闭统一认证自动登录失败', error, stackTrace);
    }
  }

  void _logAutoLoginFailure(
    String message,
    Object error,
    StackTrace stackTrace,
  ) {
    AppLogger.instance.auth(
      LogLevel.warn,
      message,
      error: error,
      stackTrace: stackTrace,
    );
  }

  @override
  void dispose() {
    unawaited(_releaseManualAttempt?.call());
    _captchaCancelToken?.cancel('Login page closed');
    _loginCancelToken?.cancel('Login page closed');
    _invalidateChallenge(_challengeId);
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _captchaCtrl.dispose();
    _usernameFocusNode.dispose();
    _passwordFocusNode.dispose();
    _captchaFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showHeader) ...[
            const SizedBox(height: 24),
            Icon(Icons.account_balance_outlined, size: 56, color: cs.primary),
            const SizedBox(height: 14),
            Text(
              widget.title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
            ),
            const SizedBox(height: 8),
            Text(
              widget.description,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 28),
          ],

          TextField(
            controller: _usernameCtrl,
            focusNode: _usernameFocusNode,
            decoration: const InputDecoration(
              hintText: '一卡通账号',
              prefixIcon: Icon(Icons.person_outline),
            ),
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _passwordFocusNode.requestFocus(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordCtrl,
            focusNode: _passwordFocusNode,
            decoration: InputDecoration(
              hintText: '一卡通密码',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                onPressed: () {
                  setState(() {
                    _obscurePassword = !_obscurePassword;
                  });
                },
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _captchaFocusNode.requestFocus(),
          ),
          const SizedBox(height: 12),
          CaptchaRow(
            controller: _captchaCtrl,
            focusNode: _captchaFocusNode,
            hintText: '验证码',
            bytes: _captchaBytes,
            loading: _loading,
            captchaLoading: _captchaLoading,
            hasError: _error != null,
            onRefresh: _refreshCaptcha,
            onSubmitted: _login,
          ),
          // 就绪后整条帮助行隐藏，不留空白 Padding/SizedBox。
          if (_captchaLoading) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '正在准备验证码...',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
              ),
            ),
          ],
          RememberAccountTile(
            value: _rememberAccount,
            onChanged: (value) => setState(() => _rememberAccount = value),
          ),
          const SizedBox(height: 6),
          FilledButton(
            onPressed:
                (_loading ||
                    _captchaLoading ||
                    _captchaBytes == null ||
                    _challengeId == null)
                ? null
                : _login,
            child: _loading
                ? SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.onPrimary,
                    ),
                  )
                : const Text('登录'),
          ),

          if (_error != null) ...[
            const SizedBox(height: 12),
            AppBanner(
              message: _error!,
              icon: Icons.error_outline,
              tone: AppBannerTone.error,
            ),
          ],
        ],
      ),
    );
  }
}
