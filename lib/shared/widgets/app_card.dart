import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/glass_style_controller.dart';
import 'app_surface_style.dart';

/// 统一的内容卡片容器。
///
/// 收敛散落在各页面的内联 `Container + BoxDecoration` 卡片，统一圆角/边框/阴影语义。
/// 圆角默认 [AppRadius.card]。
///
/// 卡面质感由 [appSurfaceDecoration] / [appSurfaceShadows] 提供：平色填充 +
/// 均匀 hairline 描边 + 落底投影，浅/深双模式独立调参（见
/// app_surface_style.dart）。玻璃参数全部来自 [GlassStyleController]
/// （`ValueListenableBuilder` 监听 enabled/tintOpacity），本组件不持有独立
/// 数值参数；`glassEnabled = false` 时直接走实色形态。
///
/// 卡片是内容面，**永不创建 BackdropFilter**（内容背后没有富媒体，模糊只会
/// 白耗 GPU）：玻璃形态只是半透明 tint。需要真实模糊的悬浮卡片请改用
/// GlassContainer（ClipRRect 必须处于 BackdropFilter 的祖先位置，否则会糊
/// 整屏）。全局玻璃开关关闭时自动降级为实色形态。
///
/// [backgroundBuilder] 提供自定义背景（品牌渐变卡等）时整幅铺满、不参与
/// ring/fill 配方，此时投影回退为 [elevation] 令牌语义；标准卡面的投影固定
/// 使用配方双层影，[elevation] 不生效。
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

  /// 仅自定义背景（[backgroundBuilder]）卡片使用：以令牌几何 + 主题影色
  /// 构建投影；标准卡面使用 [appSurfaceShadows] 配方，此参数被忽略。
  final BoxShadow elevation;

  /// 可选背景装饰（如渐变品牌卡），覆盖默认 Surface 填色。
  final BoxDecoration? Function(
    BuildContext context,
    BorderRadius borderRadius,
  )?
  backgroundBuilder;

  @override
  Widget build(BuildContext context) {
    if (!glassEnabled) return _buildSurface(context, glassEnabled: false);

    final style = GlassStyleController.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: style.enabled,
      builder: (context, glassOn, _) {
        return ValueListenableBuilder<double>(
          valueListenable: style.tintOpacity,
          builder: (context, tintOpacity, _) {
            return _buildSurface(
              context,
              glassEnabled: glassOn,
              tintOpacity: tintOpacity,
            );
          },
        );
      },
    );
  }

  Widget _buildSurface(
    BuildContext context, {
    required bool glassEnabled,
    double tintOpacity = 0,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderRadius = BorderRadius.circular(radius);
    final customBackground = backgroundBuilder?.call(context, borderRadius);

    // 自定义背景（品牌渐变卡等）：整幅铺满 + elevation 令牌投影，不走配方。
    if (customBackground != null) {
      return _withTap(
        context,
        borderRadius: borderRadius,
        shadows: [
          AppElevation.withColor(elevation, isDark ? Colors.black : cs.shadow),
        ],
        child: ClipRRect(
          borderRadius: borderRadius,
          child: Container(
            decoration: customBackground,
            padding: padding,
            child: child,
          ),
        ),
      );
    }

    // 标准卡面：平色填充 + 均匀 hairline 描边，装饰直接作用于卡面。
    final surface = Container(
      decoration: appSurfaceDecoration(
        cs: cs,
        isDark: isDark,
        glassEnabled: glassEnabled,
        borderRadius: borderRadius,
        tintAlpha: isDark ? tintOpacity * 0.86 : tintOpacity,
      ),
      padding: padding,
      child: child,
    );

    return _withTap(
      context,
      borderRadius: borderRadius,
      shadows: appSurfaceShadows(isDark: isDark),
      child: surface,
    );
  }

  /// 投影 + 可点包装：涟漪由 InkWell 的 customBorder 裁成 squircle。
  Widget _withTap(
    BuildContext context, {
    required BorderRadius borderRadius,
    required List<BoxShadow> shadows,
    required Widget child,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: shadows),
      child: onTap == null && onLongPress == null
          ? child
          : Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                customBorder: RoundedSuperellipseBorder(
                  borderRadius: borderRadius,
                ),
                child: child,
              ),
            ),
    );
  }
}
