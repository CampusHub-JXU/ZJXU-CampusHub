import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/glass_style_controller.dart';

/// A secondary-action button with real backdrop blur and theme-aware edges.
///
/// The flat translucent fill is intentionally paired with a visible hairline
/// border and a small shadow. This keeps the control discoverable on both
/// light and dark backgrounds instead of relying on blur alone. When glass
/// effects are disabled globally, the button falls back to an opaque Material
/// surface.
class GlassButton extends StatefulWidget {
  const GlassButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.expanded = false,
    this.blurred = true,
    this.foregroundColor,
  });

  factory GlassButton.text({
    Key? key,
    required VoidCallback? onPressed,
    required String text,
    IconData? icon,
    bool expanded = false,
    bool blurred = true,
    Color? foregroundColor,
  }) {
    return GlassButton(
      key: key,
      onPressed: onPressed,
      icon: icon,
      expanded: expanded,
      blurred: blurred,
      foregroundColor: foregroundColor,
      child: Text(text),
    );
  }

  final VoidCallback? onPressed;
  final Widget child;
  final IconData? icon;
  final bool expanded;

  /// Whether to create a [BackdropFilter] while glass effects are enabled.
  ///
  /// Set this to false for dense button groups where the translucent tint is
  /// sufficient and the extra GPU cost is not justified.
  final bool blurred;

  /// Defaults to the current theme's primary color.
  final Color? foregroundColor;

  @override
  State<GlassButton> createState() => _GlassButtonState();
}

class _GlassButtonState extends State<GlassButton> {
  bool _pressed = false;
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final style = GlassStyleController.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([
        style.enabled,
        style.blurSigma,
        style.tintOpacity,
      ]),
      builder: (context, _) => _buildButton(context, style),
    );
  }

  Widget _buildButton(BuildContext context, GlassStyleController style) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final enabled = widget.onPressed != null;
    final useGlass = style.shouldBlur();
    final useBlur = useGlass && widget.blurred;
    final foreground = enabled
        ? (widget.foregroundColor ?? cs.primary)
        : cs.onSurface.withValues(alpha: 0.38);
    final borderColor = _focused && enabled
        ? (widget.foregroundColor ?? cs.primary).withValues(alpha: 0.78)
        : isDark
        ? Colors.white.withValues(alpha: useGlass ? 0.24 : 0.16)
        : cs.outlineVariant.withValues(alpha: useGlass ? 0.88 : 0.72);

    final scale = enabled && _pressed ? 0.975 : 1.0;
    final shadows = _buttonShadows(
      isDark: isDark,
      enabled: enabled,
      lifted: _hovered || _focused,
    );

    final content = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      constraints: const BoxConstraints(minHeight: 48),
      decoration: ShapeDecoration(
        color: useGlass
            ? _glassFill(
                cs: cs,
                isDark: isDark,
                enabled: enabled,
                tintOpacity: style.tintOpacity.value,
              )
            : _solidFill(cs, isDark, enabled),
        shape: StadiumBorder(side: BorderSide(color: borderColor, width: 1)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onPressed,
          borderRadius: BorderRadius.circular(999),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (!enabled) return Colors.transparent;
            if (states.contains(WidgetState.pressed)) {
              return foreground.withValues(alpha: isDark ? 0.18 : 0.12);
            }
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)) {
              return foreground.withValues(alpha: isDark ? 0.10 : 0.07);
            }
            return Colors.transparent;
          }),
          onHighlightChanged: enabled
              ? (value) => setState(() => _pressed = value)
              : null,
          onFocusChange: (value) => setState(() => _focused = value),
          onHover: (value) => setState(() => _hovered = value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            child: IconTheme(
              data: IconThemeData(color: foreground, size: 18),
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
                child: _buttonChild(),
              ),
            ),
          ),
        ),
      ),
    );

    final clipped = ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: useBlur
          ? BackdropFilter(
              filter: ImageFilter.compose(
                outer: ImageFilter.blur(
                  sigmaX: style.sigmaFor(GlassTier.card),
                  sigmaY: style.sigmaFor(GlassTier.card),
                ),
                inner: const ColorFilter.matrix(<double>[
                  1.05, 0, 0, 0, 0,
                  0, 1.05, 0, 0, 0,
                  0, 0, 1.05, 0, 0,
                  0, 0, 0, 1, 0,
                ]),
              ),
              child: content,
            )
          : content,
    );

    final button = AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOutCubic,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          boxShadow: shadows,
        ),
        child: clipped,
      ),
    );

    return Semantics(
      button: true,
      enabled: enabled,
      child: widget.expanded
          ? SizedBox(width: double.infinity, child: button)
          : button,
    );
  }

  Widget _buttonChild() {
    if (widget.icon == null) return widget.child;
    return Row(
      mainAxisSize: widget.expanded ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(widget.icon),
        const SizedBox(width: 8),
        widget.child,
      ],
    );
  }
}

Color _solidFill(ColorScheme cs, bool isDark, bool enabled) {
  final fill = isDark ? cs.surfaceContainerHigh : cs.surfaceContainerLowest;
  return enabled
      ? fill
      : Color.alphaBlend(cs.onSurface.withValues(alpha: 0.04), fill);
}

/// 平色玻璃填充：品牌色微染的半透明 tint，无方向性高光；
/// 按压反馈完全交给 InkWell overlay 与缩放动画。
Color _glassFill({
  required ColorScheme cs,
  required bool isDark,
  required bool enabled,
  required double tintOpacity,
}) {
  final base = isDark ? cs.surfaceContainerLow : cs.surfaceContainerLowest;
  final alpha = isDark
      ? (tintOpacity * 0.68).clamp(0.46, 0.68).toDouble()
      : (tintOpacity * 0.72).clamp(0.52, 0.76).toDouble();
  return Color.alphaBlend(
    cs.primary.withValues(alpha: enabled ? 0.035 : 0.012),
    base.withValues(alpha: alpha),
  );
}

List<BoxShadow> _buttonShadows({
  required bool isDark,
  required bool enabled,
  required bool lifted,
}) {
  if (!enabled) return const [];
  if (isDark) {
    return [
      BoxShadow(
        color: const Color(0x73000000),
        blurRadius: lifted ? 18 : 14,
        offset: Offset(0, lifted ? 6 : 4),
      ),
    ];
  }
  // 浅色模式零投影：边界由 hairline 描边与 tint 表达。
  return const [];
}
