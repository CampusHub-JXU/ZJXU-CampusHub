import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../models/home_presentation.dart';

/// 高优先级事件横幅：通透轻量提醒条（2.5px 竖向强调条 + 文案 + 尾部箭头）。
///
/// 仅在真正需要用户处理时出现（临近考试 / 低电量 / 低余额），
/// 无事件时整块不渲染，不做常驻占位。以低对比半透明底色与细腻描边融入
/// Hero 流体背景，避免厚重实体色块破坏首屏排版呼吸感。
class HomeEventBanner extends StatelessWidget {
  const HomeEventBanner({super.key, required this.alert, this.onTap});

  final HomeAlertPresentation alert;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final bannerColor = isDark
        ? Color.alphaBlend(
            cs.error.withValues(alpha: 0.06),
            cs.surfaceContainerHigh.withValues(alpha: 0.56),
          )
        : Color.alphaBlend(
            cs.error.withValues(alpha: 0.05),
            cs.surface.withValues(alpha: 0.72),
          );
    final borderColor = isDark
        ? cs.outlineVariant.withValues(alpha: 0.42)
        : cs.error.withValues(alpha: 0.18);
    final bannerShape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(AppRadius.badge),
      side: BorderSide(color: borderColor, width: 1),
    );
    final decoration = ShapeDecoration(color: bannerColor, shape: bannerShape);

    final inner = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 38),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            Container(
              width: 2.5,
              height: 14,
              decoration: BoxDecoration(
                color: cs.error,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                alert.message,
                style: theme.textTheme.bodyMedium!.copyWith(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  height: 1.32,
                  color: cs.onSurface,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: cs.onSurfaceVariant,
              ),
            ],
          ],
        ),
      ),
    );

    if (onTap == null) {
      return DecoratedBox(decoration: decoration, child: inner);
    }

    return Semantics(
      button: true,
      label: alert.message,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: decoration,
          child: InkWell(customBorder: bannerShape, onTap: onTap, child: inner),
        ),
      ),
    );
  }
}
