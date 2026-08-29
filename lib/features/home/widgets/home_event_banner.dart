import 'package:flutter/material.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../models/home_presentation.dart';

/// 高优先级事件横幅：警告色轻量条（图标 + 文案 + 可选跳转）。
///
/// 仅在真正需要用户处理时出现（临近考试 / 低电量 / 低余额），
/// 无事件时整块不渲染，不做常驻占位。
class HomeEventBanner extends StatelessWidget {
  const HomeEventBanner({super.key, required this.alert, this.onTap});

  final HomeAlertPresentation alert;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 深色下调 errorContainer 的饱和度/亮度，避免横幅视觉权重压过 Hero。
    final bannerColor = isDark
        ? Color.alphaBlend(
            cs.errorContainer.withValues(alpha: 0.70),
            cs.surfaceContainerLow,
          )
        : cs.errorContainer;
    final icon = switch (alert.kind) {
      HomeAlertKind.examSoon => Icons.quiz_outlined,
      HomeAlertKind.lowElectricity => Icons.bolt_outlined,
      HomeAlertKind.lowBalance => Icons.account_balance_wallet_outlined,
    };
    final content = Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: bannerColor,
        borderRadius: BorderRadius.circular(AppRadius.input),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              alert.message,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onErrorContainer,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 8),
            Icon(
              Icons.arrow_forward_ios,
              size: 12,
              color: cs.onErrorContainer.withValues(alpha: 0.8),
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return content;

    return Semantics(
      button: true,
      label: alert.message,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.input),
          onTap: onTap,
          child: content,
        ),
      ),
    );
  }
}
