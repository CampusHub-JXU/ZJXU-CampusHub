import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/auth/credential_store.dart';
import '../../core/auth/zhengfang_auth.dart';
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
typedef AcademicCredentialLoader = Future<(String, String)?> Function();
typedef AcademicCredentialSaver = Future<void> Function(
  String username,
  String password,
);
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
    this.credentialLoader,
    this.credentialSaver,
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
  final AcademicCredentialLoader? credentialLoader;
  final AcademicCredentialSaver? credentialSaver;
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

  Uint8List? _captchaBytes;
  bool _loading = false;
  bool _obscurePassword = true;
  String? _error;
  ZhengfangMode _mode = ZhengfangMode.direct;
  _AcademicLoginStage _stage = _AcademicLoginStage.detecting;

  static const _proxyHint = '请求超时，请检查手机系统代理或 VPN 软件';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _loadSaved();
    if (!mounted) return;
    await _detectLoginPath();
  }

  Future<void> _detectLoginPath() async {
    if (mounted) {
      setState(() {
        _stage = _AcademicLoginStage.detecting;
        _captchaBytes = null;
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
    if (!mounted) return;
    setState(() {
      _stage = _AcademicLoginStage.preparingAcademic;
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
    if (!mounted) return;
    setState(() {
      _stage = _AcademicLoginStage.academic;
      _captchaBytes = null;
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
    final previousError = preserveError ? _error : null;
    try {
      final bytes =
          await widget.captchaLoader?.call() ??
          await ZhengfangAuth.instance.fetchCaptcha();
      final codec = await ui.instantiateImageCodec(bytes);
      codec.dispose();
      if (!mounted) return;
      setState(() {
        _captchaBytes = bytes;
        _error = previousError;
      });
    } on CaptchaException catch (error) {
      if (!mounted) return;
      if (_mode == ZhengfangMode.webVpn &&
          (error.message.contains('已过期') || error.message.contains('认证'))) {
        ZhengfangAuth.instance.markWebVpnLoggedOut();
        setState(() {
          _stage = _AcademicLoginStage.unifiedAuth;
          _captchaBytes = null;
          _error = '一卡通认证已过期，请重新认证';
        });
        return;
      }
      setState(() {
        _captchaBytes = null;
        _error = error.message;
      });
    } on DioException catch (error) {
      if (!mounted) return;
      setState(() {
        _captchaBytes = null;
        _error = _friendlyNetworkMessage(error, fallback: '无法加载验证码，请重试');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _captchaBytes = null;
        _error = _friendlyNetworkMessage(error, fallback: '无法加载验证码，请重试');
      });
    }
  }

  String _friendlyNetworkMessage(Object error, {required String fallback}) {
    final text = error.toString().toLowerCase();
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
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    final captcha = _captchaCtrl.text.trim();
    if (username.isEmpty || password.isEmpty || captcha.isEmpty) {
      setState(() => _error = '请填写学号、密码和验证码');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final result =
        await widget.loginHandler?.call(username, password, captcha) ??
        await ZhengfangAuth.instance.login(username, password, captcha);
    if (!mounted) return;

    switch (result) {
      case LoginSuccess():
        await (widget.credentialSaver?.call(username, password) ??
            CredentialStore.instance.saveCredentials(username, password));
        widget.onLoginSuccess();
      case LoginFailure(:final message):
        setState(() {
          _loading = false;
          _error = message;
        });
        _captchaCtrl.clear();
        await _refreshCaptcha(preserveError: true);
    }
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _captchaCtrl.dispose();
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
              size: 64,
              color: colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              '登录教务系统',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 32),
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
            Text(
              _error!,
              style: TextStyle(color: colorScheme.error, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
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
          decoration: const InputDecoration(
            hintText: '学号',
            prefixIcon: Icon(Icons.person_outline),
          ),
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordCtrl,
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
        ),
        const SizedBox(height: 12),
        _buildCaptchaRow(colorScheme),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            _captchaBytes == null ? '正在准备教务验证码...' : '点击右侧验证码刷新',
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
          ),
        ),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: (_loading || _captchaBytes == null) ? null : _login,
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

  Widget _buildCaptchaRow(ColorScheme colorScheme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: TextField(
            controller: _captchaCtrl,
            decoration: const InputDecoration(
              hintText: '教务验证码',
              prefixIcon: Icon(Icons.shield_outlined),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _login(),
          ),
        ),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: _refreshCaptcha,
          child: Container(
            width: 140,
            height: 72,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: AppRadius.inputBorder,
              border: Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                width: 0.8,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(15),
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
                  : _error != null
                  ? Icon(Icons.refresh, color: colorScheme.error, size: 24)
                  : const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}
