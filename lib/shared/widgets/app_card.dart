import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';

/// 统一的内容卡片容器。
///
/// 收敛散落在各页面的内联 `Container + BoxDecoration` 卡片，统一圆角/边框/阴影语义。
/// 圆角默认 [AppRadius.card]；阴影默认 [AppElevation.level1]。
/// 毛玻璃为可选参数（调用方自行传入 blur/opacity），本组件不依赖 HomeController，
/// 以保证 `shared/widgets` → `features/*` 的 DAG 单向依赖。
///
/// 严禁用于底部导航、输入表单主区域、长列表承载层（遵循 design-guidelines 红线）。
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
    this.radius = AppRadius.card,
    this.glassEnabled = false,
    this.glassBlur = 10.0,
    this.glassOpacity = 0.84,
    this.elevation = AppElevation.level1,
    this.backgroundBuilder,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool glassEnabled;
  final double glassBlur;
  final double glassOpacity;
  final BoxShadow elevation;

  /// 可选背景装饰（如渐变品牌卡），覆盖默认 Surface 填色。
  final BoxDecoration? Function(
    BuildContext context,
    BorderRadius borderRadius,
  )?
  backgroundBuilder;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderRadius = BorderRadius.circular(radius);

    final bgColor = glassEnabled
        ? (isDark
              ? cs.surfaceContainerLowest.withValues(alpha: glassOpacity * 0.86)
              : cs.surfaceContainerLowest.withValues(alpha: glassOpacity))
        : (isDark ? cs.surfaceContainerLowest : cs.surfaceContainerLowest);
    final borderColor = glassEnabled
        ? (isDark
              ? Colors.white.withValues(alpha: 0.12)
              : cs.outlineVariant.withValues(alpha: 0.32))
        : (isDark
              ? cs.outline.withValues(alpha: 0.3)
              : cs.outlineVariant.withValues(alpha: 0.48));

    final customBackground = backgroundBuilder?.call(context, borderRadius);
    final content = Container(
      decoration:
          customBackground ??
          BoxDecoration(
            color: bgColor,
            borderRadius: borderRadius,
            border: Border.all(color: borderColor, width: 1),
          ),
      padding: padding,
      child: child,
    );

    final clippedContent = ClipRRect(
      borderRadius: borderRadius,
      child: glassEnabled
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: glassBlur, sigmaY: glassBlur),
              child: content,
            )
          : content,
    );

    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          AppElevation.withColor(elevation, isDark ? Colors.black : cs.shadow),
        ],
      ),
      child: onTap == null && onLongPress == null
          ? clippedContent
          : Material(
              color: Colors.transparent,
              borderRadius: borderRadius,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                borderRadius: borderRadius,
                onTap: onTap,
                onLongPress: onLongPress,
                child: clippedContent,
              ),
            ),
    );

    return decorated;
  }
}
