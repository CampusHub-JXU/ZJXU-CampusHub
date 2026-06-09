import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/auth/credential_store.dart';
import '../../core/auth/zhengfang_auth.dart';

class LoginWidget extends StatefulWidget {
  const LoginWidget({
    super.key,
    required this.onLoginSuccess,
    this.showHeader = true,
    this.padding = const EdgeInsets.all(24),
  });

  final VoidCallback onLoginSuccess;
  final bool showHeader;
  final EdgeInsetsGeometry padding;

  @override
  State<LoginWidget> createState() => _LoginWidgetState();
}

class _LoginWidgetState extends State<LoginWidget> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _captchaCtrl = TextEditingController();

  Uint8List? _captchaBytes;
  bool _loading = false;
  bool _obscurePassword = true;
  String? _error;

  bool _autoDetecting = true;

  static const _proxyHint = '请求超时，请检查手机系统代理或 VPN 软件';

  @override
  void initState() {
    super.initState();
    _loadSaved();
    _autoDetectNetwork();
  }

  Future<void> _autoDetectNetwork() async {
    if (!_autoDetecting) return;

    try {
      final directReachable = await ZhengfangAuth.checkDirectReachable();
      if (!mounted) return;

      if (directReachable) {
        setState(() {
          _autoDetecting = false;
        });
        ZhengfangAuth.instance.setMode(ZhengfangMode.direct);
        await _refreshCaptcha();
        return;
      }

      setState(() {
        _autoDetecting = false;
        _captchaBytes = null;
        _error = '无法连接教务系统，请检查网络或在校园网环境下使用';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _autoDetecting = false;
        _captchaBytes = null;
        _error = _friendlyNetworkMessage(error, fallback: '教务系统初始化失败，请稍后重试');
      });
    }
  }

  Future<void> _loadSaved() async {
    final creds = await CredentialStore.instance.loadCredentials();
    if (creds != null) {
      _usernameCtrl.text = creds.$1;
      _passwordCtrl.text = creds.$2;
    }
  }

  Future<void> _refreshCaptcha() async {
    try {
      final bytes = await ZhengfangAuth.instance.fetchCaptcha();
      final codec = await ui.instantiateImageCodec(bytes);
      codec.dispose();
      if (mounted) {
        setState(() {
          _captchaBytes = bytes;
          _error = null;
        });
      }
    } on CaptchaException catch (e) {
      if (mounted) {
        setState(() {
          _captchaBytes = null;
          _error = e.message;
        });
      }
    } on DioException catch (e) {
      if (mounted) {
        setState(() {
          _captchaBytes = null;
          _error = _friendlyNetworkMessage(e, fallback: '无法加载验证码，请重试');
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _captchaBytes = null;
          _error = '无法加载验证码，请重试';
        });
      }
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
    final result = await ZhengfangAuth.instance.login(
      username,
      password,
      captcha,
    );
    if (!mounted) return;
    switch (result) {
      case LoginSuccess():
        await CredentialStore.instance.saveCredentials(username, password);
        widget.onLoginSuccess();
      case LoginFailure(:final message):
        setState(() {
          _loading = false;
          _error = message;
        });
        _captchaCtrl.clear();
        _refreshCaptcha();
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
            Icon(Icons.school_outlined, size: 64, color: colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              '登录教务系统',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 32),
          ],

          if (_autoDetecting)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Column(
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    '正在检测网络环境...',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),

          if (!_autoDetecting) ...[
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
            ),
            const SizedBox(height: 12),
            _buildCaptchaRow(colorScheme),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '点击右侧验证码刷新',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _loading ? null : _login,
              child: _loading
                  ? SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colorScheme.onPrimary,
                      ),
                    )
                  : const Text('登录'),
            ),
          ],

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

  Widget _buildCaptchaRow(ColorScheme colorScheme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: TextField(
            controller: _captchaCtrl,
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
          onTap: _refreshCaptcha,
          child: Container(
            width: 140,
            height: 72,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
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
