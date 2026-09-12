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
              color: cs.shadow.withValues(alpha: 0.05),
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
    usernameFilled: setInputValue(
      ['#username', 'input[name="username"]', 'input[name="login_name"]'],
      $username
    ),
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

  Widget _buildWebViewPopupMenu() {
    return PopupMenuButton<_WebViewMenuAction>(
      icon: const Icon(Icons.more_vert),
      tooltip: '更多操作',
      onSelected: (action) {
        switch (action) {
          case _WebViewMenuAction.refresh:
            _reloadCurrentPage();
          case _WebViewMenuAction.openExternal:
            _openCurrentUrlInExternalBrowser();
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: _WebViewMenuAction.refresh,
          child: Row(
            children: [
              Icon(Icons.refresh, size: 20),
              SizedBox(width: 12),
              Text('刷新'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: _WebViewMenuAction.openExternal,
          child: Row(
            children: [
              Icon(Icons.open_in_browser, size: 20),
              SizedBox(width: 12),
              Text('在浏览器中打开'),
            ],
          ),
        ),
      ],
    );
  }

  Future<String> _resolveCurrentActiveUrl() async {
    final controller = _controller;
    if (controller != null) {
      try {
        final currentWebUri = await controller.getUrl();
        final candidate = currentWebUri?.toString().trim();
        if (candidate != null && candidate.isNotEmpty) {
          _currentUrl = candidate;
          return candidate;
        }
      } catch (error) {
        _logWebViewLifecycle('获取实时 URL 失败，使用记录 URL：$error');
      }
    }
    return _currentUrl;
  }

  Future<void> _openCurrentUrlInExternalBrowser() async {
    final activeUrl = await _resolveCurrentActiveUrl();
    if (!isExternalHttpUrl(activeUrl)) {
      _showHint('当前链接无效或不支持在外部浏览器打开');
      return;
    }

    if (isSensitiveAuthIntermediateUrl(activeUrl)) {
      _showHint('当前页面处于登录认证跳转中，请在页面完全加载后再尝试外部打开');
      return;
    }

    final success = await openInExternalBrowser(activeUrl);
    if (!success && mounted) {
      _showHint('未能调起系统外部浏览器');
    }
  }

  /// 底部导航条：已移除页面内悬浮返回小岛控件（改为 AppBar 后退与系统手势拦截），
  /// 此处返回空组件以保持布局结构纯净。
  Widget _buildWebViewNavigationBar() {
    return const SizedBox.shrink();
  }

  Widget _buildError() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_off, size: 64, color: cs.onSurfaceVariant),
          const SizedBox(height: 16),
          const Text('页面加载失败'),
          const SizedBox(height: 12),
          FilledButton(onPressed: _reloadCurrentPage, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// 悬浮「网页内返回」小岛按钮本体。
///
/// 保留此类以向后兼容历史预览测试（test/preview/preview_render_test.dart），
/// 实际页面内已废弃未挂载，后续待预览测试更新后可整体清理。
@Deprecated('网页内返回小岛已废弃，保留仅为兼容 preview_render_test.dart 编译')
class WebViewBackPill extends StatelessWidget {
  const WebViewBackPill({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.92),
      elevation: 3,
      shadowColor: cs.shadow.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_back_ios_new, size: 13, color: cs.onSurface),
              const SizedBox(width: 6),
              Text(
                '网页内返回',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
