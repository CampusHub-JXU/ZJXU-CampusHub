import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/glass_style_controller.dart';
import '../../core/theme/surface_material.dart';
import 'app_surface_style.dart';
import 'frost_grain.dart';

export '../../core/theme/glass_style_controller.dart' show GlassTier;
export '../../core/theme/surface_material.dart'
    show MaterialRecipe, SurfaceMaterialStyle;

/// 统一表面材质容器。
///
/// 由统一的 [MaterialRecipe] 驱动渲染，跟随全局开关
/// [GlassStyleController.enabled] 派生具体材质：
/// * 开 —— [SurfaceMaterialStyle.acrylic]：背景采样模糊 + tint + 柔和描边；
/// * 关 —— [SurfaceMaterialStyle.solid]：实色不透明表面，无实时模糊，最省 GPU。
///
/// 铁律：
/// 1. 裁剪 [ClipRRect] 必须严格位于 [BackdropFilter] 的祖先位置；
/// 2. 使用 [ImageFilterConfig.blur]（bounded）限制背景采样范围，彻底杜绝边缘溢色（edge bleed）；
/// 3. 禁止使用任何黑白高光渐变（No white-black-white gradient），材质层次完全交由 hairline 描边与真实采样。
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.tier = GlassTier.card,
    this.borderRadius,
    this.padding,
    this.width,
    this.height,
    this.alignment,
    this.blurred,
    this.onTap,
  });

  final Widget child;

  final GlassTier tier;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;
  final AlignmentGeometry? alignment;

  /// 覆盖默认模糊策略：显式 `false` 关闭真实模糊（密集列表/内容不悬浮时省
  /// GPU），显式 `true` 强制开启，null 时跟随档位与材质配方默认。
  final bool? blurred;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final radius = borderRadius ?? AppRadius.cardBorder;
    final style = GlassStyleController.instance;

    return ListenableBuilder(
      listenable: style.surfaceChanged,
      builder: (context, _) {
        final recipe = MaterialRecipe.resolve(style.materialStyle);
        return _buildSurface(
          context,
          recipe: recipe,
          isDark: isDark,
          cs: cs,
          radius: radius,
          grain: style.frostGrainEnabled.value,
        );
      },
    );
  }

  Widget _buildSurface(
    BuildContext context, {
    required MaterialRecipe recipe,
    required bool isDark,
    required ColorScheme cs,
    required BorderRadius radius,
    required bool grain,
  }) {
    final useBlur = (blurred ?? true) && recipe.usesBackdropBlur;
    final baseSurface = isDark
        ? cs.surfaceContainerLow
        : cs.surfaceContainerLowest;

    final fillColor = switch (recipe.style) {
      SurfaceMaterialStyle.solid => baseSurface,
      SurfaceMaterialStyle.acrylic =>
        useBlur
            ? frostedFillColor(
                base: baseSurface,
                isDark: isDark,
                alpha: _fillAlpha(recipe),
              )
            : baseSurface,
    };

    final borderColor = _borderColor(recipe, isDark, cs);

    final content = Container(
      width: width,
      height: height,
      alignment: alignment,
      padding: padding,
      decoration: ShapeDecoration(
        color: fillColor,
        image: grain && useBlur && recipe.style == SurfaceMaterialStyle.acrylic
            ? frostGrainImage(isDark: isDark)
            : null,
        shadows: useBlur ? _shadows(isDark, recipe) : null,
        shape: RoundedSuperellipseBorder(
          borderRadius: radius,
          side: BorderSide(color: borderColor, width: isDark ? 0.8 : 1.0),
        ),
      ),
      child: child,
    );

    // 关键约束：
    // 1. ClipRRect 必须严格处于 BackdropFilter 祖先位置；
    // 2. 局部受限采样（bounded blur）避免边缘溢色（edge bleed）。
    Widget layer = content;
    if (useBlur) {
      final sigma = _blurSigma(recipe);
      layer = BackdropFilter(
        filterConfig: acrylicBackdropFilter(
          recipe,
          sigma: sigma,
          bounded: true,
        ),
        child: content,
      );
    }
    final clipped = ClipRRect(borderRadius: radius, child: layer);

    if (onTap == null) return clipped;

    return Material(
      color: Colors.transparent,
      child: InkWell(borderRadius: radius, onTap: onTap, child: clipped),
    );
  }

  /// 模糊强度：按配方再乘档位系数，保证 nav/overlay 仍略重于卡片。
  double _blurSigma(MaterialRecipe recipe) {
    final factor = switch (tier) {
      GlassTier.card => 1.0,
      GlassTier.nav => 1.2,
      GlassTier.overlay => 1.4,
    };
    return (recipe.blurSigma * factor).clamp(0.0, 44.0);
  }

  /// 填充不透明度：配方值并按档位加一点保底，避免底栏/弹层过透。
  double _fillAlpha(MaterialRecipe recipe) {
    final base = recipe.surfaceOpacity;
    if (tier == GlassTier.card) return base;
    return (base + 0.15).clamp(0.0, 1.0);
  }

  Color _borderColor(MaterialRecipe recipe, bool isDark, ColorScheme cs) {
    if (recipe.style == SurfaceMaterialStyle.solid) {
      return cs.outlineVariant.withValues(alpha: recipe.borderOpacity);
    }
    return frostedBorderColor(recipe: recipe, isDark: isDark);
  }

  List<BoxShadow> _shadows(bool isDark, MaterialRecipe recipe) {
    // 浅色模式零投影：磨砂面靠 tint 差异 + hairline 分层，弱影只会糊成灰雾。
    if (!isDark || recipe.shadowOpacity <= 0.001) return const [];
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: recipe.shadowOpacity),
        blurRadius: 16,
        offset: const Offset(0, 4),
      ),
    ];
  }
}
