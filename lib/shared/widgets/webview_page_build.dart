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
