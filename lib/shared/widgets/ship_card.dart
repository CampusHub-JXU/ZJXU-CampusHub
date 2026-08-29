import 'package:flutter/material.dart';

/// Ship-Card: The signature component of the Academic Voyager design system.
///
/// - Top-left/right radius: 16dp, bottom-left/right radius: 8dp（squircle 连续曲率）
/// - Hairline border / shadow semantics aligned with GlassContainer solid tier
/// - Background: surface-container-lowest
class ShipCard extends StatelessWidget {
  const ShipCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.color,
    this.gradient,
    this.elevation = 0,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Color? color;
  final Gradient? gradient;
  final double elevation;
  final Clip clipBehavior;

  static const BorderRadius _borderRadius = BorderRadius.only(
    topLeft: Radius.circular(16),
    topRight: Radius.circular(16),
    bottomLeft: Radius.circular(8),
    bottomRight: Radius.circular(8),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final surfaceColor = color ?? cs.surfaceContainerLowest;

    // 边框语义与 GlassContainer 实色档一致：深色 white 0.10 / 浅色 outlineVariant 0.55。
    final shape = RoundedSuperellipseBorder(
      borderRadius: _borderRadius,
      side: BorderSide(
        color: isDark
            ? Colors.white.withValues(alpha: 0.10)
            : cs.outlineVariant.withValues(alpha: 0.55),
        width: isDark ? 0.8 : 1.0,
      ),
    );

    // 阴影语义与 GlassContainer 一致：elevation > 0 时按深浅主题取固定档位。
    final shadows = elevation > 0
        ? isDark
              ? const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                ]
              : const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 14,
                    offset: Offset(0, 4),
                  ),
                ]
        : null;

    Widget content = Container(
      padding: padding,
      decoration: ShapeDecoration(
        color: gradient == null ? surfaceColor : null,
        gradient: gradient,
        shape: shape,
        shadows: shadows,
      ),
      child: child,
    );

    if (onTap != null) {
      content = Material(
        color: Colors.transparent,
        shape: shape,
        clipBehavior: clipBehavior,
        child: InkWell(onTap: onTap, customBorder: shape, child: content),
      );
    }

    return Padding(padding: margin, child: content);
  }
}
