import 'package:flutter/material.dart';

/// 统一的空态视图：图标 + 标题 + 描述 + 可选操作按钮。
///
/// 与 [AppErrorView] 同构（居中 + 限宽 + 图标容器），但走中性色，不携带
/// 错误语义。用于「暂无数据 / 尚未配置」类分支；带引导动作时通过
/// `actionLabel` + `onAction` 提供（如「去选择寝室」）。
class AppEmptyView extends StatelessWidget {
  const AppEmptyView({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? message;
  final IconData icon;

  /// 可选的引导按钮文案；与 [onAction] 同时提供才会渲染按钮。
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasMessage = message != null && message!.isNotEmpty;
    final hasAction = actionLabel != null && onAction != null;

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
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: cs.onSurfaceVariant, size: 28),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (hasMessage) ...[
                const SizedBox(height: 6),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
              if (hasAction) ...[
                const SizedBox(height: 20),
                FilledButton.tonal(
                  onPressed: onAction,
                  child: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
