import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/glass_style_controller.dart';
import '../../core/theme/surface_material.dart';
import 'app_surface_style.dart';
import 'material_noise.dart';

/// 可点卡面的统一质感容器。
///
/// 两种形态，实时监听 [GlassStyleController]：
/// * **亚克力**（全局风格为 [SurfaceMaterialStyle.acrylic]，即
///   [GlassStyleController.enabled] 开启）——ClipRSuperellipse → BackdropFilter
///   （非 bounded 模糊 + 提饱和，按 [MaterialRecipe]）→ Material → Ink（半透明
///   填充 + hairline 描边）→ InkWell，内容下方铺一层程序化颗粒。裁剪严格
///   位于 BackdropFilter 祖先位置，避免糊整屏。
/// * **平色**——Material → Ink(配方装饰) → InkWell，零 BackdropFilter；
///   [GlassStyleController.enabled] 关闭时即为实色。
///
/// 涟漪绘制在 Material 上、由 customBorder 裁成 squircle。
class AppTileSurface extends StatelessWidget {
  const AppTileSurface({
    super.key,
    required this.child,
    this.borderRadius,
    this.padding,
    this.onTap,
    this.onLongPress,
  });

  final Widget child;

  /// 卡面圆角；空时取 [AppRadius.tileBorder]。
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final style = GlassStyleController.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: style.enabled,
      builder: (context, _, _) => _buildSurface(context, style),
    );
  }

  Widget _buildSurface(BuildContext context, GlassStyleController style) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final radius = borderRadius ?? AppRadius.tileBorder;
    final glassEnabled = style.enabled.value;

    final recipe = MaterialRecipe.resolve(style.materialStyle);
    final useAcrylic =
        recipe.style == SurfaceMaterialStyle.acrylic && recipe.usesBackdropBlur;

    final shape = RoundedSuperellipseBorder(borderRadius: radius);
    Widget content = Padding(padding: padding ?? EdgeInsets.zero, child: child);
    if (useAcrylic && recipe.hasNoise) {
      // 颗粒画在内容之下（CustomPaint.painter），不遮挡文字与涟漪命中。
      content = CustomPaint(
        painter: MaterialNoisePainter(
          opacity: recipe.noiseOpacity,
          isDark: isDark,
        ),
        child: content,
      );
    }

    final decoration = useAcrylic
        ? ShapeDecoration(
            color: (isDark ? cs.surfaceContainerLow : cs.surfaceContainerLowest)
                .withValues(alpha: recipe.surfaceOpacity),
            shape: RoundedSuperellipseBorder(
              borderRadius: radius,
              side: BorderSide(
                color: isDark
                    ? Colors.white.withValues(alpha: recipe.borderOpacity * 0.2)
                    : cs.outlineVariant.withValues(alpha: recipe.borderOpacity),
                width: isDark ? 0.8 : 1.0,
              ),
            ),
          )
        : appSurfaceDecoration(
            cs: cs,
            isDark: isDark,
            glassEnabled: glassEnabled,
            borderRadius: radius,
            tintAlpha: isDark
                ? kSurfaceTintOpacity * 0.86
                : kSurfaceTintOpacity,
          );

    final surface = Material(
      color: Colors.transparent,
      child: Ink(
        decoration: decoration,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          customBorder: shape,
          child: content,
        ),
      ),
    );

    if (!useAcrylic) return surface;

    final sigma = recipe.blurSigma;
    return ClipRSuperellipse(
      borderRadius: radius,
      child: BackdropFilter(
        filterConfig: ImageFilterConfig.compose(
          outer: ImageFilterConfig.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            // 不用 bounded：Impeller（Android OpenGLES，模拟器实测）下
            // bounded 模糊与提饱和组合，会在卡面底边上方约 10dp 处画出一条
            // 紫/青色横条。外层 ClipRSuperellipse 已限定输出区域，非
            // bounded 只让边缘多采一点外侧壁纸，不会糊出卡面。
            bounded: false,
          ),
          inner: ImageFilterConfig(
            ColorFilter.matrix(saturationColorMatrix(recipe.saturation)),
          ),
        ),
        child: surface,
      ),
    );
  }
}
