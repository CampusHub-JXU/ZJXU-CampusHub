import 'package:flutter/material.dart';

/// 统一的错误态视图：图标 + 标题 + 描述 + 重试按钮。
///
/// 收敛各页面散落的「裸 Text + FilledButton 重试」错误分支（如宿舍楼栋/寝室
/// 选择流程、考试、通知等），统一为主题派生的图标容器 + 标题层级 + 可选描述
/// + 可选重试按钮。样式与 [AuthRequiredView] 保持同一节奏（居中 + 限宽）。
///
/// `- message` 用于携带具体错误信息（如异常文案），为空时自动省略该行；
/// `- onRetry` 为 null 时隐藏重试按钮（如页面顶部已有刷新入口）；
/// `- retryLabel` 允许页面自定义按钮文案（默认「重试」）。
class AppErrorView extends StatelessWidget {
  const AppErrorView({
    super.key,
    this.title = '加载失败',
    this.message,
    this.onRetry,
    this.retryLabel = '重试',
    this.icon = Icons.cloud_off_rounded,
  });

  final String title;
  final String? message;
  final VoidCallback? onRetry;
  final String retryLabel;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasMessage = message != null && message!.isNotEmpty;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: cs.errorContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: cs.onErrorContainer, size: 28),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (hasMessage) ...[
                const SizedBox(height: 6),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
              if (onRetry != null) ...[
                const SizedBox(height: 20),
                FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(retryLabel),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
