part of 'webview_page.dart';

extension _WebViewPageBuildExtension on _WebViewPageState {
  Widget _buildQuickFillBar() {
    if (!widget.enableLoginQuickFill || _quickFillKind == null) {
      return const SizedBox.shrink();
    }

    final cs = Theme.of(context).colorScheme;
    final kind = _quickFillKind!;
    final credentials = kind == WebViewQuickFillKind.zhengfang
        ? _savedZhengfangCredentials
        : _savedUnifiedCredentials;
    final title = kind == WebViewQuickFillKind.zhengfang ? '教务快速填充' : '一卡通快速填充';
    final description = credentials == null
        ? '还没有记住账号密码，先用应用内登录一次后这里会自动复用'
        : '检测到已保存账号密码，可一键填入当前网页登录表单';

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(top: BorderSide(color: cs.outlineVariant)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              description,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            if (credentials != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _quickFillBusy
                        ? null
                        : () => _fillSavedCredentials(
                            fillUsername: true,
                            fillPassword: true,
                          ),
                    icon: const Icon(Icons.auto_fix_high, size: 18),
                    label: const Text('一键填充'),
                  ),
                  OutlinedButton(
                    onPressed: _quickFillBusy
                        ? null
                        : () => _fillSavedCredentials(
                            fillUsername: true,
                            fillPassword: false,
                          ),
                    child: const Text('填账号'),
                  ),
                  OutlinedButton(
                    onPressed: _quickFillBusy
                        ? null
                        : () => _fillSavedCredentials(
                            fillUsername: false,
                            fillPassword: true,
                          ),
                    child: const Text('填密码'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _fillSavedCredentials({
    required bool fillUsername,
    required bool fillPassword,
  }) async {
    final controller = _controller;
    final kind = _quickFillKind;
    if (controller == null || kind == null || _quickFillBusy) return;

    final credentials = switch (kind) {
      WebViewQuickFillKind.zhengfang => _savedZhengfangCredentials,
      WebViewQuickFillKind.unifiedAuth => _savedUnifiedCredentials,
    };

    if (credentials == null) {
      final loginType = kind == WebViewQuickFillKind.zhengfang ? '教务' : '一卡通';
      _showHint('还没有记住$loginType账号密码，请先用应用内登录一次');
      return;
    }

    _setQuickFillBusy(true);

    final username = jsonEncode(fillUsername ? credentials.$1 : '');
    final password = jsonEncode(fillPassword ? credentials.$2 : '');
    final script = switch (kind) {
      WebViewQuickFillKind.zhengfang =>
        '''
(() => {
  const setInputValue = (selectors, value) => {
    if (!value) return false;
    for (const selector of selectors) {
      const input = document.querySelector(selector);
      if (!input) continue;
      input.focus();
      input.value = value;
      input.dispatchEvent(new Event('input', { bubbles: true }));
      input.dispatchEvent(new Event('change', { bubbles: true }));
      return true;
    }
    return false;
  };

  return {
    usernameFilled: setInputValue(['#yhm', 'input[name="yhm"]'], $username),
    passwordFilled: setInputValue(
      ['#mm', 'input[name="mm"]', 'input[type="password"]'],
      $password
    ),
  };
})()
''',
      WebViewQuickFillKind.unifiedAuth =>
        '''
(() => {
  const setInputValue = (selectors, value) => {
    if (!value) return false;
    for (const selector of selectors) {
      const input = document.querySelector(selector);
      if (!input) continue;
      input.focus();
      input.value = value;
      input.dispatchEvent(new Event('input', { bubbles: true }));
      input.dispatchEvent(new Event('change', { bubbles: true }));
      return true;
    }
    return false;
  };

  return {
    usernameFilled: setInputValue(['#username', 'input[name="username"]'], $username),
    passwordFilled: setInputValue(
      ['#password', 'input[name="password"]', 'input[type="password"]'],
      $password
    ),
  };
})()
''',
    };

    try {
      final result = await controller.evaluateJavascript(source: script);
      final resultMap = result is Map
          ? Map<Object?, Object?>.from(result)
          : const {};
      final usernameFilled = '${resultMap['usernameFilled']}' == 'true';
      final passwordFilled = '${resultMap['passwordFilled']}' == 'true';

      if (!mounted) return;

      if ((fillUsername && !usernameFilled) ||
          (fillPassword && !passwordFilled)) {
        _showHint('当前登录页字段未识别到，请手动输入');
      } else {
        _showHint(
          kind == WebViewQuickFillKind.zhengfang ? '已填充教务账号密码' : '已填充一卡通账号密码',
        );
      }
    } catch (error) {
      AppLogger.instance.webview(
        LogLevel.error,
        'WebView 快速填充失败: $_currentUrl :: $error',
      );
      _showHint('快速填充失败，请手动输入');
    } finally {
      _setQuickFillBusy(false);
    }
  }

  Widget _buildWebViewNavigationBar() {
    if (!widget.showWebViewBottomBackButton) {
      return const SizedBox.shrink();
    }

    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(top: BorderSide(color: cs.outlineVariant)),
        ),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _canGoBackInWebView ? _goBackInWebViewIfPossible : null,
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            label: const Text('网页内返回'),
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text('页面加载失败'),
          const SizedBox(height: 12),
          FilledButton(onPressed: _reloadCurrentPage, child: const Text('重试')),
        ],
      ),
    );
  }
}
