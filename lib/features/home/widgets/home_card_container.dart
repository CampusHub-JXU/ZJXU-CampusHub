import 'package:flutter/material.dart';

import '../../../shared/widgets/glass_container.dart';

/// 首页仪表盘卡片容器。
///
/// 玻璃材质与参数统一由 [GlassContainer]（GlassStyleController）提供，
/// 这里只保留首页卡片的尺寸/内边距约定与点击行为。
class HomeCardContainer extends StatelessWidget {
  const HomeCardContainer({
    super.key,
    required this.child,
    this.height,
    this.width = double.infinity,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
    this.onTap,
    this.onLongPress,
  });

  final Widget child;
  final double? height;
  final double width;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final content = GlassContainer(
      tier: GlassTier.card,
      width: width,
      height: height,
      padding: padding,
      blurred: true,
      onTap: onTap,
      child: child,
    );

    if (onLongPress == null) return content;

    return GestureDetector(onLongPress: onLongPress, child: content);
  }
}
