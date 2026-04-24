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
    return ValueListenableBuilder<bool>(
      valueListenable: HomeController.instance.frostedGlassEnabled,
      builder: (context, _, _) {
        return ValueListenableBuilder<double>(
          valueListenable: HomeController.instance.glassBlur,
          builder: (context, _, _) {
            return ValueListenableBuilder<double>(
              valueListenable: HomeController.instance.glassOpacity,
              builder: (context, _, _) => _buildContent(context),
            );
          },
        );
      },
    );
  }

  Widget _buildContent(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final glassEnabled = HomeController.instance.frostedGlassEnabled.value;
    final glassBlur = HomeController.instance.glassBlur.value;
    final glassOpacity = HomeController.instance.glassOpacity.value;
    final radius = BorderRadius.circular(20);
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
    final shadowColor = isDark
        ? Colors.black.withValues(alpha: glassEnabled ? 0.14 : 0.08)
        : cs.shadow.withValues(alpha: glassEnabled ? 0.06 : 0.04);

    final content = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: radius,
        border: Border.all(color: borderColor, width: 1),
      ),
      padding: padding,
      child: child,
    );

    final clippedContent = ClipRRect(
      borderRadius: radius,
      child: glassEnabled
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: glassBlur, sigmaY: glassBlur),
              child: content,
            )
          : content,
    );

    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: shadowColor,
            blurRadius: glassEnabled ? 14 : 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: onTap == null
          ? clippedContent
          : Material(
              color: Colors.transparent,
              borderRadius: radius,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                borderRadius: radius,
                onTap: onTap,
                child: clippedContent,
              ),
            ),
    );

    return decorated;
  }
}
