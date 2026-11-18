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
    return ExcludeSemantics(
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}
