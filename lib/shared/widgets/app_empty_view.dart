import 'package:flutter/material.dart';

import '../../core/theme/app_typography.dart';
import 'app_state_view_transition.dart';

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
    final text = context.appText;
    final hasMessage = message != null && message!.isNotEmpty;
    final hasAction = actionLabel != null && onAction != null;

    // 整块内容走统一的淡入 + 轻微上浮，避免 loading → 空态瞬切。
    return AppStateViewTransition(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // v2 状态图标的唯一形态：44dp 圆形底 + 20dp 线性图标。
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: cs.onSurfaceVariant, size: 22),
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: text.rowTitleStrong,
                ),
                if (hasMessage) ...[
                  const SizedBox(height: 4),
                  Text(message!, textAlign: TextAlign.center, style: text.meta),
                ],
                if (hasAction) ...[
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: onAction,
                    child: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
