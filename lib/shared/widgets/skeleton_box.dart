import 'package:material_ui/material_ui.dart';

/// 无缓存首次加载时的占位骨架块（见 design-guidelines 4.5）。
///
/// 刻意做成静态色块而不是无限脉冲：无限动画会让 widget 测试里的
/// `pumpAndSettle` 永不结束，也省掉首屏多余的重绘。
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    required this.height,
    this.radius = 6,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = Color.alphaBlend(
      cs.onSurface.withValues(alpha: isDark ? 0.09 : 0.04),
      cs.surfaceContainerHighest,
    );
    final highlight = Color.alphaBlend(
      cs.onSurface.withValues(alpha: isDark ? 0.15 : 0.08),
      cs.surfaceContainerHighest,
    );
    return ExcludeSemantics(
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [base, highlight, base],
          ),
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}

/// 卡片形态的骨架占位：外框带微弱描边与表面底色，内部排列主/副文本条，
/// 避免纯暗/纯亮背景下整块色块与背景融成一片空白。
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({
    super.key,
    this.radius = 16,
    this.padding = const EdgeInsets.all(16),
    this.lines = 2,
    this.showTrailing = false,
  });

  final double radius;
  final EdgeInsetsGeometry padding;
  final int lines;
  final bool showTrailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ExcludeSemantics(
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: isDark ? 0.36 : 0.45),
            width: 0.8,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SkeletonBox(width: 148, height: 15, radius: 5),
                  if (lines >= 2) ...[
                    const SizedBox(height: 10),
                    const SkeletonBox(width: 210, height: 12, radius: 4),
                  ],
                  if (lines >= 3) ...[
                    const SizedBox(height: 8),
                    const SkeletonBox(width: 112, height: 12, radius: 4),
                  ],
                ],
              ),
            ),
            if (showTrailing) ...[
              const SizedBox(width: 12),
              const SkeletonBox(width: 48, height: 24, radius: 12),
            ],
          ],
        ),
      ),
    );
  }
}
