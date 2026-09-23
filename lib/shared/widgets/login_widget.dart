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
import '../../core/auth/zhengfang_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/theme/app_design_tokens.dart';
import 'unified_auth_login_widget.dart';

typedef AcademicReachabilityChecker = Future<bool> Function();
typedef AcademicGatewaySessionEnsurer = Future<bool?> Function();
typedef AcademicCaptchaLoader = Future<Uint8List> Function();
typedef AcademicLoginHandler = Future<LoginResult> Function(
  String username,
  String password,
  String captcha,
);
typedef AcademicChallengeLoader = Future<CaptchaChallenge> Function({
  CancelToken? cancelToken,
});
typedef AcademicChallengeLoginHandler = Future<LoginResult> Function({
  required String challengeId,
  required String username,
  required String password,
  required String captcha,
  CancelToken? cancelToken,
});
typedef AcademicChallengeInvalidator = void Function(String challengeId);
typedef AcademicCredentialLoader = Future<(String, String)?> Function();
typedef AcademicCredentialSaver = Future<void> Function(
  String username,
  String password,
);
typedef AcademicCredentialClearer = Future<void> Function();

/// 「记住账号并自动登录」勾选后启用该域自动恢复（可注入，默认走协调器）。
typedef AcademicAutoLoginEnabler = Future<AuthRecoveryEnableResult> Function(
  String account,
);

/// 登录成功且自动恢复已启用时记录一次成功（可注入，默认走协调器）。
typedef AcademicAutoLoginSuccessRecorder = Future<void> Function();

/// 未勾选时关闭该域自动恢复（可注入，默认走协调器）。
typedef AcademicAutoLoginDisabler = Future<void> Function();

typedef AcademicModeSetter = void Function(ZhengfangMode mode);
typedef UnifiedAuthStageBuilder = Widget Function(
  BuildContext context,
  VoidCallback onLoginSuccess,
);

class LoginWidget extends StatefulWidget {
  const LoginWidget({
    super.key,
    required this.onLoginSuccess,
    this.showHeader = true,
    this.padding = const EdgeInsets.all(24),
    this.directReachabilityChecker,
    this.webVpnReachabilityChecker,
    this.gatewaySessionEnsurer,
    this.captchaLoader,
    this.loginHandler,
    this.challengeLoader,
    this.challengeLoginHandler,
    this.challengeInvalidator,
    this.credentialLoader,
    this.credentialSaver,
    this.credentialClearer,
    this.enableAutoLogin,
    this.recordAutoLoginSuccess,
    this.disableAutoLogin,
    this.modeSetter,
    this.unifiedAuthStageBuilder,
  });

  final VoidCallback onLoginSuccess;
  final bool showHeader;
  final EdgeInsetsGeometry padding;
  final AcademicReachabilityChecker? directReachabilityChecker;
  final AcademicReachabilityChecker? webVpnReachabilityChecker;
  final AcademicGatewaySessionEnsurer? gatewaySessionEnsurer;
  final AcademicCaptchaLoader? captchaLoader;
  final AcademicLoginHandler? loginHandler;
  final AcademicChallengeLoader? challengeLoader;
  final AcademicChallengeLoginHandler? challengeLoginHandler;
  final AcademicChallengeInvalidator? challengeInvalidator;
  final AcademicCredentialLoader? credentialLoader;
  final AcademicCredentialSaver? credentialSaver;
  final AcademicCredentialClearer? credentialClearer;
  final AcademicAutoLoginEnabler? enableAutoLogin;
  final AcademicAutoLoginSuccessRecorder? recordAutoLoginSuccess;
  final AcademicAutoLoginDisabler? disableAutoLogin;
  final AcademicModeSetter? modeSetter;
  final UnifiedAuthStageBuilder? unifiedAuthStageBuilder;

  @override
  State<LoginWidget> createState() => _LoginWidgetState();
}

enum _AcademicLoginStage {
  detecting,
  unifiedAuth,
  preparingAcademic,
  academic,
  unavailable,
}

class _LoginWidgetState extends State<LoginWidget> {
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
  ZhengfangMode _mode = ZhengfangMode.direct;
  _AcademicLoginStage _stage = _AcademicLoginStage.detecting;

  static const _proxyHint = '请求超时，请检查手机系统代理或 VPN 软件';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  void _invalidateChallenge(String? challengeId) {
    if (challengeId == null) return;
    final invalidator = widget.challengeInvalidator;
    if (invalidator != null) {
      invalidator(challengeId);
      return;
    }
    ZhengfangAuth.instance.invalidateChallenge(challengeId: challengeId);
  }

  Future<void> _bootstrap() async {
    await _loadSaved();
    if (!mounted) return;
    await _detectLoginPath();
  }

  Future<void> _detectLoginPath() async {
    _captchaCancelToken?.cancel('Stage changed');
    _invalidateChallenge(_challengeId);
    if (mounted) {
      setState(() {
        _stage = _AcademicLoginStage.detecting;
        _captchaBytes = null;
        _challengeId = null;
        _error = null;
      });
    }

    try {
      final directReachable =
          await widget.directReachabilityChecker?.call() ??
          await ZhengfangAuth.checkDirectReachable();
      if (!mounted) return;

      if (directReachable) {
        _setMode(ZhengfangMode.direct);
        await _enterAcademicStage();
        return;
      }

      final webVpnReachable =
          await widget.webVpnReachabilityChecker?.call() ??
          await ZhengfangAuth.checkWebVpnReachable();
      if (!mounted) return;

      if (!webVpnReachable) {
        setState(() {
          _stage = _AcademicLoginStage.unavailable;
          _error = '无法连接教务系统，请检查网络连接';
        });
        return;
      }

      _setMode(ZhengfangMode.webVpn);
      final gatewayReady = await _ensureGatewaySession();
      if (!mounted) return;

      if (gatewayReady) {
        await _enterAcademicStage();
      } else {
        setState(() {
          _stage = _AcademicLoginStage.unifiedAuth;
          _error = null;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _AcademicLoginStage.unavailable;
        _error = _friendlyNetworkMessage(error, fallback: '教务系统初始化失败，请稍后重试');
      });
    }
  }

  void _setMode(ZhengfangMode mode) {
    if (_mode != mode) {
      _invalidateChallenge(_challengeId);
      _challengeId = null;
      _captchaBytes = null;
    }
    _mode = mode;
    final setter = widget.modeSetter;
    if (setter != null) {
      setter(mode);
    } else {
      ZhengfangAuth.instance.setMode(mode);
    }
  }

  Future<bool> _ensureGatewaySession() async {
    final result =
        await widget.gatewaySessionEnsurer?.call() ??
        await ZhengfangAuth.instance.ensureWebVpnGatewaySession(
          syncWebViewCookies: false,
        );
    return result == true;
  }

  Future<void> _handleUnifiedAuthSuccess() async {
    _captchaCancelToken?.cancel('Stage changed');
    _invalidateChallenge(_challengeId);
    if (!mounted) return;
    setState(() {
      _stage = _AcademicLoginStage.preparingAcademic;
      _captchaBytes = null;
      _challengeId = null;
      _error = null;
    });

    try {
      final gatewayReady = await _ensureGatewaySession();
      if (!mounted) return;
      if (!gatewayReady) {
        setState(() {
          _stage = _AcademicLoginStage.unavailable;
          _error = '一卡通认证完成，但 WebVPN 会话校验失败，请重新检测';
        });
        return;
      }
      await _enterAcademicStage();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _AcademicLoginStage.unavailable;
        _error = _friendlyNetworkMessage(
          error,
          fallback: 'WebVPN 会话建立失败，请重新检测',
        );
      });
    }
  }

  Future<void> _enterAcademicStage() async {
    _captchaCancelToken?.cancel('Stage changed');
    _invalidateChallenge(_challengeId);
    if (!mounted) return;
    setState(() {
      _stage = _AcademicLoginStage.academic;
      _captchaBytes = null;
      _challengeId = null;
      _error = null;
    });
    await _refreshCaptcha();
  }

  Future<void> _loadSaved() async {
    final credentials =
        await widget.credentialLoader?.call() ??
        await CredentialStore.instance.loadCredentials();
    if (credentials != null) {
      _usernameCtrl.text = credentials.$1;
      _passwordCtrl.text = credentials.$2;
    }
  }

  Future<void> _refreshCaptcha({bool preserveError = false}) async {
    if (_loading || _captchaLoading) return;
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

    try {
      final challengeResult =
          await Future.any<({Uint8List bytes, String id})>([
            (() async {
              if (token.isCancelled) throw token.cancelError!;
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
              final ch = await ZhengfangAuth.instance.prepareCaptchaChallenge(
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
    } on CaptchaException catch (error) {
      if (!mounted || requestId != _captchaRequestId) return;
      if (_mode == ZhengfangMode.webVpn &&
          (error.message.contains('已过期') || error.message.contains('认证'))) {
        ZhengfangAuth.instance.markWebVpnLoggedOut();
        setState(() {
          _stage = _AcademicLoginStage.unifiedAuth;
          _captchaBytes = null;
          _challengeId = null;
          _error = '一卡通认证已过期，请重新认证';
        });
        return;
      }
      setState(() {
        _captchaBytes = null;
        _challengeId = null;
        _error = error.message;
      });
    } on DioException catch (error) {
      if (!mounted || requestId != _captchaRequestId) return;
      if (error.type == DioExceptionType.cancel &&
          error.error is! TimeoutException) {
        return;
      }
      setState(() {
        _captchaBytes = null;
        _challengeId = null;
        _error = _friendlyNetworkMessage(error, fallback: '无法加载验证码，请重试');
      });
    } catch (error) {
      if (!mounted || requestId != _captchaRequestId) return;
      setState(() {
        _captchaBytes = null;
        _challengeId = null;
        _error = _friendlyNetworkMessage(error, fallback: '无法加载验证码，请重试');
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
    final text = error.toString().toLowerCase();
    if (error is TimeoutException) {
      return '$_proxyHint，然后重试登录';
    }
    if (text.contains('handshakeexception') ||
        text.contains('connection terminated during handshake')) {
      return '无法连接教务系统，请检查系统代理、VPN 或网络证书环境后重试';
    }
    if (error is DioException) {
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        return '$_proxyHint，然后重试登录';
      }
      if (error.type == DioExceptionType.connectionError) {
        return '无法连接教务系统，请检查网络或系统代理设置';
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
      setState(() => _error = '请填写学号、密码和验证码');
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
      final LoginResult result;
      if (widget.challengeLoginHandler != null) {
        result = await widget.challengeLoginHandler!(
          challengeId: challengeId,
          username: username,
          password: password,
          captcha: captcha,
          cancelToken: token,
        );
      } else if (widget.loginHandler != null) {
        result = await widget.loginHandler!(username, password, captcha);
      } else {
        result = await ZhengfangAuth.instance.submitCaptchaChallenge(
          challengeId: challengeId,
          username: username,
          password: password,
          captcha: captcha,
          cancelToken: token,
        );
      }
      if (!mounted || token.isCancelled) return;

      switch (result) {
        case LoginSuccess():
          await _applyAutoLoginPreference(
            username: username,
            password: password,
          );
          if (!mounted) return;
          widget.onLoginSuccess();
        case LoginFailure(:final message, :final kind):
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
    } on DioException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _friendlyNetworkMessage(error, fallback: '登录未完成，请重试');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _friendlyNetworkMessage(error, fallback: '登录未完成，请重试');
      });
    } finally {
      token.cancel('Login finished');
      if (mounted) {
        setState(() => _loading = false);
      }
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
        await (widget.credentialSaver?.call(username, password) ??
            CredentialStore.instance.saveCredentials(username, password));
      } catch (error, stackTrace) {
        _logAutoLoginFailure('保存教务凭据失败', error, stackTrace);
      }

      final AuthRecoveryEnableResult enableResult;
      try {
        enableResult =
            await (widget.enableAutoLogin?.call(username) ??
                AuthOperationCoordinator.instance.enableAutomaticRecovery(
                  AuthRecoveryDomain.academic,
                  expectedAccount: username,
                ));
      } catch (error, stackTrace) {
        _logAutoLoginFailure('启用教务自动登录失败', error, stackTrace);
        return;
      }
      if (enableResult != AuthRecoveryEnableResult.enabled) {
        AppLogger.instance.auth(
          LogLevel.warn,
          '教务自动登录未启用（${enableResult.name}），登录成功不受影响',
        );
        return;
      }

      try {
        await (widget.recordAutoLoginSuccess?.call() ??
            AuthOperationCoordinator.instance.recordSuccess(
              AuthRecoveryDomain.academic,
            ));
      } catch (error, stackTrace) {
        _logAutoLoginFailure('记录教务登录成功失败', error, stackTrace);
      }
      return;
    }

    try {
      await (widget.credentialClearer?.call() ??
          CredentialStore.instance.clearCredentials());
    } catch (error, stackTrace) {
      _logAutoLoginFailure('清除教务凭据失败', error, stackTrace);
    }
    try {
      await (widget.disableAutoLogin?.call() ??
          AuthOperationCoordinator.instance.disableAutomaticRecovery(
            AuthRecoveryDomain.academic,
          ));
    } catch (error, stackTrace) {
      _logAutoLoginFailure('关闭教务自动登录失败', error, stackTrace);
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
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showHeader) ...[
            const SizedBox(height: 24),
            Icon(
              _mode == ZhengfangMode.direct
                  ? Icons.school_outlined
                  : Icons.vpn_lock_outlined,
              size: 56,
              color: colorScheme.primary,
            ),
            const SizedBox(height: 14),
            Text(
              '登录教务系统',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
            ),
            const SizedBox(height: 28),
          ],
          if (_stage == _AcademicLoginStage.detecting ||
              _stage == _AcademicLoginStage.preparingAcademic)
            _buildProgressState(colorScheme),
          if (_stage == _AcademicLoginStage.unifiedAuth)
            _buildUnifiedAuthStage(context, colorScheme),
          if (_stage == _AcademicLoginStage.academic)
            _buildAcademicStage(colorScheme),
          if (_stage == _AcademicLoginStage.unavailable)
            OutlinedButton.icon(
              onPressed: _detectLoginPath,
              icon: const Icon(Icons.refresh),
              label: const Text('重新检测'),
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            _buildErrorBanner(colorScheme),
          ],
        ],
      ),
    );
  }

  /// 错误提示横幅：图标 + 单段文案，浅/深色均用 errorContainer 底色分层，
  /// 比裸居中红字更易读；文案本身保持调用方语义不变。
  Widget _buildErrorBanner(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: AppRadius.chipBorder,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline,
            size: 16,
            color: colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: TextStyle(
                color: colorScheme.onErrorContainer,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressState(ColorScheme colorScheme) {
    final preparingAcademic = _stage == _AcademicLoginStage.preparingAcademic;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            preparingAcademic ? '正在建立 WebVPN 会话...' : '正在检测网络环境...',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildUnifiedAuthStage(BuildContext context, ColorScheme colorScheme) {
    final builder = widget.unifiedAuthStageBuilder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStepLabel(
          colorScheme,
          icon: Icons.vpn_key_outlined,
          label: '第 1 步：一卡通认证',
        ),
        const SizedBox(height: 12),
        if (builder != null)
          builder(context, _handleUnifiedAuthSuccess)
        else
          UnifiedAuthLoginWidget(
            serviceUrl: ZhengfangAuth.webVpnGatewayServiceUrl,
            title: '登录一卡通',
            description: '先完成统一认证，再登录教务系统',
            sessionPreflight: _ensureGatewaySession,
            showHeader: false,
            padding: EdgeInsets.zero,
            onLoginSuccess: _handleUnifiedAuthSuccess,
          ),
      ],
    );
  }

  Widget _buildAcademicStage(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_mode == ZhengfangMode.webVpn) ...[
          _buildStepLabel(
            colorScheme,
            icon: Icons.school_outlined,
            label: '第 2 步：教务系统登录',
          ),
          const SizedBox(height: 16),
        ],
        TextField(
          controller: _usernameCtrl,
          focusNode: _usernameFocusNode,
          decoration: const InputDecoration(
            hintText: '学号',
            prefixIcon: Icon(Icons.person_outline),
          ),
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => _passwordFocusNode.requestFocus(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordCtrl,
          focusNode: _passwordFocusNode,
          decoration: InputDecoration(
            hintText: '教务系统密码',
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
        _buildCaptchaRow(colorScheme),
        // 就绪后整条帮助行隐藏，不留空白 Padding/SizedBox。
        if (_captchaLoading || _captchaBytes == null) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              '正在准备教务验证码...',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
        ],
        _buildRememberAccountTile(colorScheme),
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
                    color: colorScheme.onPrimary,
                  ),
                )
              : const Text('登录教务系统'),
        ),
      ],
    );
  }

  Widget _buildStepLabel(
    ColorScheme colorScheme, {
    required IconData icon,
    required String label,
  }) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: colorScheme.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「记住账号并自动登录」勾选行。使用紧凑自定义行而非 [CheckboxListTile]：
  /// 主/副标题两行文本在窄屏（含 600 高的最小测试视口）下不会把表单顶出可视区。
  Widget _buildRememberAccountTile(ColorScheme colorScheme) {
    return MergeSemantics(
      child: InkWell(
        onTap: () => setState(() => _rememberAccount = !_rememberAccount),
        borderRadius: AppRadius.inputBorder,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: Checkbox(
                  value: _rememberAccount,
                  onChanged: (value) =>
                      setState(() => _rememberAccount = value ?? false),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '记住账号并自动登录',
                      style: TextStyle(
                        fontSize: 14,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '自动登录并自动刷新数据；不勾选则不保存密码',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCaptchaRow(ColorScheme colorScheme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: TextField(
            controller: _captchaCtrl,
            focusNode: _captchaFocusNode,
            decoration: const InputDecoration(
              hintText: '教务验证码',
              prefixIcon: Icon(Icons.shield_outlined),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _login(),
          ),
        ),
        const SizedBox(width: 12),
        Semantics(
          button: true,
          label: '刷新验证码',
          // 内层 InkWell 关闭了自身语义，这里补上等价的 tap 动作（含加载态
          // 禁用分支），避免无障碍服务只播报按钮却无法激活刷新。
          onTap: (_loading || _captchaLoading) ? null : _refreshCaptcha,
          child: SizedBox(
            width: 140,
            height: 72,
            child: Material(
              color: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: AppRadius.inputBorder,
                side: BorderSide(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                  width: 0.8,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: (_loading || _captchaLoading) ? null : _refreshCaptcha,
                excludeFromSemantics: true,
                child: _captchaBytes != null
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                        child: Image.memory(
                          _captchaBytes!,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.high,
                        ),
                      )
                    : (_error != null && !_captchaLoading)
                    ? Icon(Icons.refresh, color: colorScheme.error, size: 24)
                    : const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
