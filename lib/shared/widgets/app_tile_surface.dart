import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/glass_style_controller.dart';
import '../../core/theme/surface_material.dart';
import 'app_surface_style.dart';
import 'frost_grain.dart';

/// 可点卡面的统一质感容器。
///
/// 两种形态，实时监听 [GlassStyleController]：
/// * **亚克力**（全局风格为 [SurfaceMaterialStyle.acrylic]，即
///   [GlassStyleController.enabled] 开启）——ClipRSuperellipse → BackdropFilter
///   （非 bounded 模糊，按 [MaterialRecipe]）→ Material → Ink（半透明
///   填充 + hairline 描边）→ InkWell。裁剪严格位于 BackdropFilter 祖先位置，
///   避免糊整屏。
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
    this.blurred = true,
  });

  final Widget child;

  /// 卡面圆角；空时取 [AppRadius.tileBorder]。
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 是否允许启用亚克力背景模糊；位于纯色纸面之上（如首页功能区）时传
  /// `false`，跳过 `BackdropFilter.grouped` 重采样以降低滚动光栅开销。
  final bool blurred;

  @override
  Widget build(BuildContext context) {
    final style = GlassStyleController.instance;
    return ListenableBuilder(
      listenable: style.surfaceChanged,
      builder: (context, _) => _buildSurface(context, style),
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
        blurred &&
        recipe.style == SurfaceMaterialStyle.acrylic &&
        recipe.usesBackdropBlur;

    final shape = RoundedSuperellipseBorder(borderRadius: radius);
    final content = Padding(padding: padding ?? EdgeInsets.zero, child: child);

    final decoration = useAcrylic
        ? ShapeDecoration(
            color: frostedFillColor(
              base: isDark ? cs.surfaceContainerLow : cs.surfaceContainerLowest,
              isDark: isDark,
              alpha: recipe.surfaceOpacity,
            ),
            image: style.frostGrainEnabled.value
                ? frostGrainImage(isDark: isDark)
                : null,
            shape: RoundedSuperellipseBorder(
              borderRadius: radius,
              side: BorderSide(
                color: frostedBorderColor(recipe: recipe, isDark: isDark),
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

    return ClipRSuperellipse(
      borderRadius: radius,
      // grouped：同一 [BackdropGroup] 下的磁贴共用一次背景读取，滚动时不再
      // 每块磁贴各自重采样壁纸（首页功能区十几块磁贴时 raster 会超预算）。
      // 没有 BackdropGroup 祖先时退化为普通 BackdropFilter。
      child: BackdropFilter.grouped(
        // 不用 bounded：Impeller（Android OpenGLES，模拟器实测）下 bounded
        // 模糊（叠提饱和时）会在卡面底边上方约 10dp 处画出一条紫/青色横条。
        // 外层 ClipRSuperellipse 已限定输出区域，非 bounded 只让边缘多采
        // 一点外侧壁纸，不会糊出卡面。
        filterConfig: acrylicBackdropFilter(
          recipe,
          sigma: recipe.blurSigma,
          bounded: false,
        ),
        child: surface,
      ),
    );
  }
}
