import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/auth/credential_store.dart';
import '../../core/auth/zhengfang_auth.dart';

/// Reusable login form widget. Calls [onLoginSuccess] when login succeeds.
class LoginWidget extends StatefulWidget {
  const LoginWidget({super.key, required this.onLoginSuccess});
  final VoidCallback onLoginSuccess;

  @override
  State<LoginWidget> createState() => _LoginWidgetState();
}

class _LoginWidgetState extends State<LoginWidget> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _captchaCtrl = TextEditingController();

  Uint8List? _captchaBytes;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSaved();
    _refreshCaptcha();
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
      if (mounted) setState(() => _captchaBytes = bytes);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '验证码加载失败，请点击图片重试');
      }
    }
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
        ZhengfangAuth.instance.markLoggedIn();
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          Icon(Icons.school_outlined, size: 64, color: colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            '登录正方教务系统',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _usernameCtrl,
            decoration: const InputDecoration(
              labelText: '学号',
              prefixIcon: Icon(Icons.person_outline),
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordCtrl,
            decoration: const InputDecoration(
              labelText: '密码',
              prefixIcon: Icon(Icons.lock_outline),
              border: OutlineInputBorder(),
            ),
            obscureText: true,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _captchaCtrl,
                  decoration: const InputDecoration(
                    labelText: '验证码',
                    prefixIcon: Icon(Icons.security),
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _login(),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: _refreshCaptcha,
                child: Container(
                  width: 120,
                  height: 56,
                  decoration: BoxDecoration(
                    border: Border.all(color: colorScheme.outline),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: _captchaBytes != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: Image.memory(_captchaBytes!, fit: BoxFit.fill),
                        )
                      : const Center(child: CircularProgressIndicator()),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: colorScheme.error, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _loading ? null : _login,
            child: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('登 录'),
          ),
          const SizedBox(height: 8),
          Text(
            '点击验证码图片可刷新',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
