import 'dart:ui';

import 'package:flutter/material.dart';

import '../home_controller.dart';

class HomeCardContainer extends StatelessWidget {
  const HomeCardContainer({
    super.key,
    required this.child,
    this.height,
    this.width = double.infinity,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
    this.onTap,
  });

  final Widget child;
  final double? height;
  final double width;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final glassEnabled = HomeController.instance.frostedGlassEnabled.value;
    final radius = BorderRadius.circular(20);
    final bgColor = glassEnabled
        ? (isDark
              ? cs.surfaceContainerLowest.withValues(alpha: 0.72)
              : Colors.white.withValues(alpha: 0.58))
        : (isDark ? cs.surfaceContainerLowest : Colors.white);
    final borderColor = glassEnabled
        ? (isDark
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.38))
        : (isDark
              ? cs.outline.withValues(alpha: 0.3)
              : cs.outline.withValues(alpha: 0.2));

    final content = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: radius,
        border: Border.all(color: borderColor, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: glassEnabled ? 0.08 : 0.05),
            blurRadius: glassEnabled ? 18 : 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: padding,
      child: child,
    );

    final decorated = glassEnabled
        ? ClipRRect(
            borderRadius: radius,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: content,
            ),
          )
        : content;

    if (onTap == null) {
      return decorated;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: decorated,
      ),
    );
  }
}
