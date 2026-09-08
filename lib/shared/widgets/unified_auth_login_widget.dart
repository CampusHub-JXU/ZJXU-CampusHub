import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';

import '../../core/auth/credential_store.dart';
import '../../core/auth/unified_auth.dart';

enum UnifiedAuthMode { direct }

typedef LoginCredentialLoader = Future<(String, String)?> Function();
typedef LoginCredentialSaver = Future<void> Function(
  String username,
  String password,
);
typedef LoginSessionPreflight = Future<bool> Function();
typedef LoginCaptchaLoader = Future<Uint8List> Function();
typedef LoginSubmitHandler = Future<String?> Function(
  String username,
  String password,
  String captcha,
);

class UnifiedAuthLoginWidget extends StatefulWidget {
  const UnifiedAuthLoginWidget({
    super.key,
    required this.onLoginSuccess,
    this.serviceUrl = UnifiedAuthService.defaultServiceUrl,
    this.title = '登录统一认证',
    this.description = '账号为校园一卡通号',
    this.loadSavedCredentials,
    this.saveCredentials,
    this.sessionPreflight,
    this.captchaLoader,
    this.loginHandler,
    this.showHeader = true,
    this.padding = const EdgeInsets.all(24),
  });

  final VoidCallback onLoginSuccess;
  final String serviceUrl;
  final String title;
  final String description;
  final LoginCredentialLoader? loadSavedCredentials;
  final LoginCredentialSaver? saveCredentials;
  final LoginSessionPreflight? sessionPreflight;
  final LoginCaptchaLoader? captchaLoader;
  final LoginSubmitHandler? loginHandler;
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
  bool _loading = false;
  bool _captchaLoading = false;
  CancelToken? _captchaCancelToken;
  bool _obscurePassword = true;
  String? _error;

  static const _proxyHint = '请求超时，请切换网络后重试；如使用代理或 VPN，请检查其设置';

  @override
  void initState() {
    super.initState();
    _refreshCaptcha(prepare: true);
  }

  Future<bool> _preparePrimaryLoginMode(CancelToken token) async {
    if (widget.sessionPreflight != null) {
      final hasActiveSession = await widget.sessionPreflight!.call();
      if (token.isCancelled) throw token.cancelError!;
      if (!mounted || hasActiveSession) {
        return hasActiveSession;
      }
    } else if (UnifiedAuthService.instance.isLoggedIn) {
      return true;
    }

    if (widget.loginHandler != null && widget.captchaLoader != null) {
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
    final token = CancelToken();
    _captchaCancelToken = token;
    setState(() {
      _captchaLoading = true;
      _captchaBytes = null;
      _error = previousError;
    });
    _captchaCtrl.clear();
    try {
      final bytes =
          await Future.any<Uint8List?>([
            (() async {
              if (prepare) {
                await _loadSaved(token);
                if (token.isCancelled) throw token.cancelError!;
                if (await _preparePrimaryLoginMode(token)) return null;
              }
              if (token.isCancelled) throw token.cancelError!;
              return await widget.captchaLoader?.call() ??
                  await UnifiedAuthService.instance.fetchCaptcha(
                    serviceUrl: widget.serviceUrl,
                    cancelToken: token,
                  );
            })(),
            token.whenCancel.then((error) => throw error),
          ]).timeout(
            const Duration(seconds: 20),
            onTimeout: () {
              token.cancel('Captcha preparation timed out');
              throw TimeoutException('Captcha preparation timed out');
            },
          );
      if (!mounted || token.isCancelled) return;
      if (bytes == null) {
        widget.onLoginSuccess();
        return;
      }
      final codec = await ui.instantiateImageCodec(bytes);
      codec.dispose();
      if (!mounted || token.isCancelled) return;
      setState(() {
        _captchaBytes = bytes;
        _error = previousError;
      });
    } on UnifiedAuthCaptchaException catch (error) {
      if (!mounted) return;
      setState(() {
        _captchaBytes = null;
        _error = error.message;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _captchaBytes = null;
        _error = _friendlyNetworkMessage(e, fallback: '验证码加载失败，请点击重试');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _captchaBytes = null;
        _error = _friendlyNetworkMessage(error, fallback: '验证码加载失败，请点击重试');
      });
    } finally {
      token.cancel('Captcha loading finished');
      if (mounted) setState(() => _captchaLoading = false);
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
    if (_loading || _captchaLoading || _captchaBytes == null) return;
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    final captcha = _captchaCtrl.text.trim();
    if (username.isEmpty || password.isEmpty || captcha.isEmpty) {
      setState(() => _error = '请填写账号、密码和验证码');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      if (widget.loginHandler != null) {
        final message = await widget.loginHandler!(username, password, captcha);
        if (!mounted) return;
        if (message == null) {
          await widget.saveCredentials?.call(username, password);
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

      final result = await UnifiedAuthService.instance.login(
        username,
        password,
        captcha,
        serviceUrl: widget.serviceUrl,
      );
      if (!mounted) return;

      switch (result) {
        case UnifiedAuthLoginSuccess():
          await (widget.saveCredentials?.call(username, password) ??
              CredentialStore.instance.saveUnifiedAuthCredentials(
                username,
                password,
              ));
          if (!mounted) return;
          widget.onLoginSuccess();
        case UnifiedAuthLoginFailure(:final message):
          setState(() {
            _loading = false;
            _error = message;
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
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _captchaCancelToken?.cancel('Login page closed');
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
            Icon(Icons.account_balance_outlined, size: 64, color: cs.primary),
            const SizedBox(height: 16),
            Text(
              widget.title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              widget.description,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 32),
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
              hintText: '密码',
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
          _buildCaptchaRow(cs),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              _captchaLoading ? '正在准备验证码...' : '点击右侧验证码刷新',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
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
                      color: cs.onPrimary,
                    ),
                  )
                : const Text('登录'),
          ),

          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: cs.error, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCaptchaRow(ColorScheme cs) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: TextField(
            controller: _captchaCtrl,
            focusNode: _captchaFocusNode,
            decoration: const InputDecoration(
              hintText: '验证码',
              prefixIcon: Icon(Icons.shield_outlined),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _login(),
          ),
        ),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: (_captchaLoading || _loading) ? null : _refreshCaptcha,
          child: Container(
            width: 140,
            height: 72,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: AppRadius.inputBorder,
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.5),
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
                  ? Icon(Icons.refresh, color: cs.error, size: 24)
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
