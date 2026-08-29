import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/glass_style_controller.dart';

/// 统一的内容卡片容器。
///
/// 收敛散落在各页面的内联 `Container + BoxDecoration` 卡片，统一圆角/边框/阴影语义。
/// 圆角默认 [AppRadius.card]；阴影默认 [AppElevation.level1]。
///
/// 毛玻璃开关与材质参数（模糊强度/tint 透明度）统一从 [GlassStyleController]
/// 读取（`ValueListenableBuilder` 监听 enabled/blurSigma/tintOpacity），本组件
/// 不再持有独立数值参数，保证全局玻璃状态一致；`shared/widgets` → `core/theme`
/// 仍为 DAG 单向依赖。
///
/// 卡片级玻璃默认不加模糊（blurred=false）：只叠加 tint 渐变 + 高光描边 +
/// squircle，不产生 BackdropFilter。若未来需要真实模糊，务必让 ClipRRect
/// 处于 BackdropFilter 的祖先位置（BackdropFilter 作用于整个父层 backdrop，
/// 不裁剪会糊整屏）。全局玻璃开关关闭时降级为与实色卡片一致的外观。
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
    this.elevation = AppElevation.level1,
    this.backgroundBuilder,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool glassEnabled;
  final BoxShadow elevation;

  /// 可选背景装饰（如渐变品牌卡），覆盖默认 Surface 填色。
  final BoxDecoration? Function(
    BuildContext context,
    BorderRadius borderRadius,
  )?
  backgroundBuilder;

  @override
  Widget build(BuildContext context) {
    if (!glassEnabled) return _buildSolid(context);

    final style = GlassStyleController.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: style.enabled,
      builder: (context, glassOn, _) {
        return ValueListenableBuilder<double>(
          // 卡片级默认不加模糊；监听 blurSigma 以保持与全局材质参数联动。
          valueListenable: style.blurSigma,
          builder: (context, _, _) {
            return ValueListenableBuilder<double>(
              valueListenable: style.tintOpacity,
              builder: (context, tintOpacity, _) {
                return glassOn
                    ? _buildGlass(context, tintOpacity)
                    : _buildSolid(context);
              },
            );
          },
        );
      },
    );
  }

  /// 实色外观（glassEnabled=false 或全局玻璃开关关闭时的降级形态）。
  Widget _buildSolid(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderRadius = BorderRadius.circular(radius);

    final bgColor = cs.surfaceContainerLowest;
    final borderColor = isDark
        ? cs.outline.withValues(alpha: 0.3)
        : cs.outlineVariant.withValues(alpha: 0.48);

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
      child: content,
    );

    return DecoratedBox(
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
  }

  /// 玻璃外观：材质参数全部来自 [GlassStyleController]，视觉语义对齐
  /// GlassContainer card tier（tint 渐变 + 高光描边 + squircle，无 BackdropFilter）。
  Widget _buildGlass(BuildContext context, double tintOpacity) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderRadius = BorderRadius.circular(radius);

    // 玻璃 tint 与高光合成为渐变：顶部受光面提亮更多，底部几乎保持 tint 本色。
    Color tintWithHighlight(double highlightAlpha) => Color.alphaBlend(
      Colors.white.withValues(alpha: highlightAlpha),
      (isDark ? cs.surfaceContainerLow : cs.surfaceContainerLowest).withValues(
        alpha: isDark ? tintOpacity * 0.86 : tintOpacity,
      ),
    );

    final customBackground = backgroundBuilder?.call(context, borderRadius);
    final content = Container(
      decoration:
          customBackground ??
          ShapeDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                tintWithHighlight(isDark ? 0.10 : 0.34),
                tintWithHighlight(isDark ? 0.02 : 0.08),
              ],
            ),
            shape: RoundedSuperellipseBorder(
              borderRadius: borderRadius,
              side: BorderSide(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.14)
                    : cs.outlineVariant.withValues(alpha: 0.55),
                width: isDark ? 0.8 : 1.0,
              ),
            ),
          ),
      padding: padding,
      child: child,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          AppElevation.withColor(elevation, isDark ? Colors.black : cs.shadow),
        ],
      ),
      child: onTap == null && onLongPress == null
          ? content
          : Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: borderRadius,
                onTap: onTap,
                onLongPress: onLongPress,
                child: content,
              ),
            ),
    );
  }
}
