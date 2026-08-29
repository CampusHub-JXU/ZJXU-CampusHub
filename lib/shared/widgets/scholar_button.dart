import 'package:flutter/material.dart';

/// ScholarButton: Primary action button with Wine Red gradient + StadiumBorder.
class ScholarButton extends StatelessWidget {
  const ScholarButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expanded = false,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final IconData? icon;
  final bool expanded;

  factory ScholarButton.text({
    Key? key,
    required VoidCallback? onPressed,
    required String text,
    IconData? icon,
    bool expanded,
  }) = _ScholarButtonText;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final gradientEnd = _shiftColor(
      cs.primary,
      lightnessDelta: -0.12,
      saturationDelta: 0.04,
    );
    final button = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [cs.primary, gradientEnd]),
        borderRadius: BorderRadius.circular(100),
        boxShadow: [
          BoxShadow(
            color: cs.primary.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(100),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            // 显式 onPrimary：child 直接传 Text 时不能继承 onSurface
            //（浅色模式会变成深色字压在深色酒红面上）。
            child: DefaultTextStyle.merge(
              style: TextStyle(
                color: cs.onPrimary,
                fontWeight: FontWeight.w600,
              ),
              child: icon != null
                  ? Row(
                      mainAxisSize: expanded
                          ? MainAxisSize.max
                          : MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, color: cs.onPrimary, size: 18),
                        const SizedBox(width: 8),
                        child,
                      ],
                    )
                  : child,
            ),
          ),
        ),
      ),
    );

    if (expanded) {
      return SizedBox(width: double.infinity, child: button);
    }
    return button;
  }
}

Color _shiftColor(
  Color color, {
  double lightnessDelta = 0,
  double saturationDelta = 0,
}) {
  final hsl = HSLColor.fromColor(color);
  return hsl
      .withLightness((hsl.lightness + lightnessDelta).clamp(0.0, 1.0))
      .withSaturation((hsl.saturation + saturationDelta).clamp(0.0, 1.0))
      .toColor();
}

class _ScholarButtonText extends ScholarButton {
  _ScholarButtonText({
    super.key,
    required super.onPressed,
    required String text,
    super.icon,
    super.expanded,
  }) : super(
         child: Builder(
           builder: (context) => Text(
             text,
             // merge 环境默认样式：保留主题字体家族，只覆盖颜色与字重。
             style: DefaultTextStyle.of(context).style.merge(
               TextStyle(
                 color: Theme.of(context).colorScheme.onPrimary,
                 fontWeight: FontWeight.w600,
               ),
             ),
           ),
         ),
       );
}

/// Secondary button: surface-container-high bg, primary text.
class ScholarSecondaryButton extends StatelessWidget {
  const ScholarSecondaryButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expanded = false,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final IconData? icon;
  final bool expanded;

  factory ScholarSecondaryButton.text({
    Key? key,
    required VoidCallback? onPressed,
    required String text,
    IconData? icon,
    bool expanded,
  }) = _ScholarSecondaryButtonText;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final button = Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(100),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(100),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            // 显式 primary：规范为「surfaceContainerHigh 底 + primary 字」，
            // child 直接传 Text 时不能继承 onSurface。
            child: DefaultTextStyle.merge(
              style: TextStyle(
                color: cs.primary,
                fontWeight: FontWeight.w600,
              ),
              child: icon != null
                  ? Row(
                      mainAxisSize: expanded
                          ? MainAxisSize.max
                          : MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, color: cs.primary, size: 18),
                        const SizedBox(width: 8),
                        child,
                      ],
                    )
                  : child,
            ),
          ),
        ),
      ),
    );

    if (expanded) {
      return SizedBox(width: double.infinity, child: button);
    }
    return button;
  }
}

class _ScholarSecondaryButtonText extends ScholarSecondaryButton {
  _ScholarSecondaryButtonText({
    super.key,
    required super.onPressed,
    required String text,
    super.icon,
    super.expanded,
  }) : super(
         child: Builder(
           builder: (context) => Text(
             text,
             // merge 环境默认样式：保留主题字体家族，只覆盖颜色与字重。
             style: DefaultTextStyle.of(context).style.merge(
               TextStyle(
                 color: Theme.of(context).colorScheme.primary,
                 fontWeight: FontWeight.w600,
               ),
             ),
           ),
         ),
       );
}
