import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/glass_style_controller.dart';
import '../../core/theme/surface_material.dart';
import 'material_noise.dart';

export '../../core/theme/glass_style_controller.dart' show GlassTier;
export '../../core/theme/surface_material.dart'
    show MaterialRecipe, MaterialSurfaceType, SurfaceMaterialStyle;

/// 统一表面材质容器（PRD 0.7.0 §20-§24，材质重构版）。
///
/// 由统一的 [MaterialRecipe] 驱动渲染，根据 [surfaceType] 或全局设置派生具体材质：
/// * [SurfaceMaterialStyle.solid] —— 实色不透明表面，无实时模糊，最省 GPU；
/// * [SurfaceMaterialStyle.glass] —— 局部受约束采样模糊（bounded blur）+ 半透明 tint + 极弱柔影，背景透出；
/// * [SurfaceMaterialStyle.acrylic] —— 背景采样模糊 + tint/明度修正 + 极细微程序化 grain（微粒）+ 柔和描边；
/// * [SurfaceMaterialStyle.mica] —— 不透明稳定主题色调表面，无实时 BackdropFilter 模糊，大面积高能效。
///
/// 铁律：
/// 1. 裁剪 [ClipRRect] 必须严格位于 [BackdropFilter] 的祖先位置；
/// 2. 使用 [ImageFilterConfig.blur]（bounded）限制背景采样范围，彻底杜绝边缘溢色（edge bleed）；
/// 3. 禁止使用任何黑白高光渐变（No white-black-white gradient），材质层次完全交由 hairline 描边与真实采样；
/// 4. 云母 (Mica) 表面永不创建 [BackdropFilter]。
class AppMaterialSurface extends StatelessWidget {
  const AppMaterialSurface({
    super.key,
    required this.child,
    this.surfaceType,
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

  /// 显式覆盖表面材质风格；为 null 时跟随全局设置 [GlassStyleController.materialStyle]。
  final MaterialSurfaceType? surfaceType;

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

    return ValueListenableBuilder<bool>(
      valueListenable: style.enabled,
      builder: (context, _, _) {
        return ValueListenableBuilder<double>(
          valueListenable: style.blurSigma,
          builder: (context, _, _) {
            return ValueListenableBuilder<double>(
              valueListenable: style.tintOpacity,
              builder: (context, _, _) {
                return ValueListenableBuilder<SurfaceMaterialStyle>(
                  valueListenable: style.materialStyle,
                  builder: (context, currentStyle, _) {
                    final effectiveStyle = surfaceType ?? currentStyle;
                    final recipe = MaterialRecipe.resolve(
                      effectiveStyle,
                      blurBase: style.blurSigma.value,
                      tintBase: style.tintOpacity.value,
                    );
                    return _buildSurface(
                      context,
                      recipe: recipe,
                      glassEnabled: style.shouldBlur(),
                      isDark: isDark,
                      cs: cs,
                      radius: radius,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildSurface(
    BuildContext context, {
    required MaterialRecipe recipe,
    required bool glassEnabled,
    required bool isDark,
    required ColorScheme cs,
    required BorderRadius radius,
  }) {
    final useBlur =
        glassEnabled && (blurred ?? true) && recipe.usesBackdropBlur;
    final baseSurface = isDark
        ? cs.surfaceContainerLow
        : cs.surfaceContainerLowest;

    final fillColor = switch (recipe.style) {
      SurfaceMaterialStyle.solid => baseSurface,
      // 云母恒为不透明稳定表面：在不透明底色上叠加可感知的主题色调，
      // 与亚克力的「半透明 + 实时模糊 + 噪点」形成明确区分。
      SurfaceMaterialStyle.mica => Color.alphaBlend(
        cs.primary.withValues(
          alpha: (recipe.tintOpacity * (isDark ? 0.42 : 0.28)).clamp(0.0, 0.2),
        ),
        baseSurface.withValues(alpha: recipe.surfaceOpacity),
      ),
      SurfaceMaterialStyle.glass ||
      SurfaceMaterialStyle.acrylic => baseSurface.withValues(
        alpha: useBlur ? _fillAlpha(recipe, isDark) : 1.0,
      ),
    };

    final borderColor = _borderColor(recipe, isDark, cs);

    Widget content = Container(
      width: width,
      height: height,
      alignment: alignment,
      padding: padding,
      decoration: ShapeDecoration(
        color: fillColor,
        shadows: useBlur ? _shadows(isDark, recipe) : null,
        shape: RoundedSuperellipseBorder(
          borderRadius: radius,
          side: BorderSide(color: borderColor, width: isDark ? 0.8 : 1.0),
        ),
      ),
      child: child,
    );

    if (recipe.hasNoise) {
      content = Stack(
        children: [
          content,
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: MaterialNoisePainter(
                  opacity: recipe.noiseOpacity,
                  isDark: isDark,
                ),
              ),
            ),
          ),
        ],
      );
    }

    // 关键约束：
    // 1. ClipRRect 必须严格处于 BackdropFilter 祖先位置；
    // 2. 局部受限采样（bounded blur）避免边缘溢色（edge bleed）。
    final sigma = _blurSigma(recipe);
    final filterConfig = recipe.saturation != 1.0
        ? ImageFilterConfig.compose(
            outer: ImageFilterConfig.blur(
              sigmaX: sigma,
              sigmaY: sigma,
              bounded: true,
            ),
            inner: ImageFilterConfig(
              ColorFilter.matrix(saturationColorMatrix(recipe.saturation)),
            ),
          )
        : ImageFilterConfig.blur(sigmaX: sigma, sigmaY: sigma, bounded: true);

    final glassLayer = ClipRRect(
      borderRadius: radius,
      child: useBlur
          ? BackdropFilter(filterConfig: filterConfig, child: content)
          : content,
    );

    if (onTap == null) return glassLayer;

    return Material(
      color: Colors.transparent,
      child: InkWell(borderRadius: radius, onTap: onTap, child: glassLayer),
    );
  }

  /// 模糊强度：玻璃风格沿用档位派生（1:1 跟随滑条），其他材质按配方
  /// 再乘档位系数，保证 nav/overlay 仍略重于卡片。
  double _blurSigma(MaterialRecipe recipe) {
    if (recipe.style == SurfaceMaterialStyle.glass) {
      return GlassStyleController.instance.sigmaFor(tier);
    }
    final factor = switch (tier) {
      GlassTier.card => 1.0,
      GlassTier.nav => 1.2,
      GlassTier.overlay => 1.4,
    };
    return (recipe.blurSigma * factor).clamp(0.0, 44.0);
  }

  /// 填充不透明度：玻璃沿用历史档位（nav 刻意偏低），其他材质用配方值并按
  /// 档位加一点保底，避免底栏/弹层过透。
  double _fillAlpha(MaterialRecipe recipe, bool isDark) {
    if (recipe.style == SurfaceMaterialStyle.glass) {
      final cardAlpha = GlassStyleController.instance.tintOpacity.value;
      if (tier == GlassTier.card) return isDark ? cardAlpha * 0.86 : cardAlpha;
      return isDark
          ? (tier == GlassTier.nav ? 0.30 : 0.58)
          : (tier == GlassTier.nav ? 0.38 : 0.66);
    }
    final base = recipe.surfaceOpacity;
    if (tier == GlassTier.card) return base;
    return (base + 0.15).clamp(0.0, 1.0);
  }

  Color _borderColor(MaterialRecipe recipe, bool isDark, ColorScheme cs) {
    final alpha = isDark
        ? (recipe.borderOpacity * 0.20).clamp(0.0, 1.0)
        : recipe.borderOpacity.clamp(0.0, 1.0);
    return isDark
        ? Colors.white.withValues(alpha: alpha)
        : cs.outlineVariant.withValues(alpha: alpha);
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

/// 兼容性子类：向后兼容既有代码对 [GlassContainer] 的使用。
class GlassContainer extends AppMaterialSurface {
  const GlassContainer({
    super.key,
    required super.child,
    super.surfaceType,
    super.tier = GlassTier.card,
    super.borderRadius,
    super.padding,
    super.width,
    super.height,
    super.alignment,
    super.blurred,
    super.onTap,
  });
}

/// 程序化噪点纹理已抽取为共享 [MaterialNoisePainter]（见 material_noise.dart）。
