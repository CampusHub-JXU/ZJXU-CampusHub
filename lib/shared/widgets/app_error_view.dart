import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_typography.dart';
import 'app_state_view_transition.dart';

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
    final text = context.appText;
    final hasMessage = message != null && message!.isNotEmpty;

    // 整块内容走统一的淡入 + 轻微上浮，避免内容 → 错误态瞬切。
    return AppStateViewTransition(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 与空态同构，只有底色 / 图标换成警示色（v2 六态状态机：
                // 「拉取失败」必须与「真为空」视觉可分）。
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: cs.errorContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: cs.onErrorContainer, size: 22),
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
                if (onRetry != null) ...[
                  const SizedBox(height: 16),
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
      ),
    );
  }
}
