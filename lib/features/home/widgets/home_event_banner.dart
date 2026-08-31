import 'package:flutter/material.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../models/home_presentation.dart';

/// 高优先级事件横幅：无框 tinted 轻量行（圆点 + 文案 + 尾部 chevron）。
///
/// 仅在真正需要用户处理时出现（临近考试 / 低电量 / 低余额），
/// 无事件时整块不渲染，不做常驻占位。视觉上以 errorContainer 低透明
/// 着色 + 8px 圆点达意，替代旧的图标条样式。
class HomeEventBanner extends StatelessWidget {
  const HomeEventBanner({super.key, required this.alert, this.onTap});

  final HomeAlertPresentation alert;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 浅色直接压低 errorContainer 透明度；深色按 alphaBlend 叠
    // surfaceContainerLow，避免横幅视觉权重压过 Hero。
    final bannerColor = isDark
        ? Color.alphaBlend(
            cs.errorContainer.withValues(alpha: 0.70),
            cs.surfaceContainerLow,
          )
        : cs.errorContainer.withValues(alpha: 0.45);
    // 圆角与内容面同档（AppRadius.card），跟随全局统一半径。
    final bannerShape = RoundedSuperellipseBorder(
      borderRadius: AppRadius.cardBorder,
    );
    final content = Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: ShapeDecoration(color: bannerColor, shape: bannerShape),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: cs.error, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              alert.message,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: cs.onErrorContainer,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right,
              size: 16,
              color: cs.onErrorContainer.withValues(alpha: 0.7),
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
        child: InkWell(customBorder: bannerShape, onTap: onTap, child: content),
      ),
    );
  }
}
