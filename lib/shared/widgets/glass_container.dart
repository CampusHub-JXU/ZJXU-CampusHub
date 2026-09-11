import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/glass_style_controller.dart';
import '../../core/theme/surface_material.dart';

/// 玻璃材质等级定义在参数中心（[GlassStyleController]），此处 re-export
/// 保持既有导入路径 `shared/widgets/glass_container.dart` 向后兼容。
export '../../core/theme/glass_style_controller.dart' show GlassTier;

/// 统一表面材质容器（PRD 0.7.0 §20-§24）。
///
/// 由 [MaterialRecipe] 驱动渲染，不再由组件各自拼装 BackdropFilter / tint /
/// border / highlight / 噪点：
/// * 实色 solid —— 不透明，无模糊；
/// * 玻璃 glass —— BackdropFilter(模糊 + 提饱和) + 低 tint + hairline + 顶部高光；
/// * 亚克力 acrylic —— 更强模糊 + 更高 tint + 噪点纹理 + 柔和描边 + 投影；
/// * 云母 mica —— 低模糊 + 高表面不透明度 + 细微噪点，适合大面积表面。
///
/// 三档 [GlassTier] 仍是「用量约束」：card / nav / overlay 在配方基础上调整
/// 模糊与填充强度，保证顶栏、底栏、弹层与卡片随全局设置同步。
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
                  builder: (context, materialStyle, _) {
                    final recipe = MaterialRecipe.resolve(
                      materialStyle,
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
    final useBlur = glassEnabled && (blurred ?? true) && recipe.usesBackdropBlur;
    final baseSurface = isDark
        ? cs.surfaceContainerLow
        : cs.surfaceContainerLowest;
    final fillColor = baseSurface.withValues(
      alpha: useBlur ? _fillAlpha(recipe, isDark) : 1.0,
    );
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

    if (recipe.hasHighlight || recipe.hasNoise) {
      content = Stack(
        children: [
          content,
          if (recipe.hasHighlight)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.center,
                      colors: [
                        Colors.white.withValues(alpha: recipe.highlightOpacity),
                        Colors.white.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (recipe.hasNoise)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _NoisePainter(
                    opacity: recipe.noiseOpacity,
                    isDark: isDark,
                  ),
                ),
              ),
            ),
        ],
      );
    }

    // 关键：裁剪必须放在 BackdropFilter 的祖先位置。
    // BackdropFilter 会把模糊作用于整个父层 backdrop 而非自身 bounds，
    // 不先裁剪就会把整屏内容糊掉。
    final glassLayer = ClipRRect(
      borderRadius: radius,
      child: useBlur
          ? BackdropFilter(
              filter: ImageFilter.compose(
                outer: ImageFilter.blur(
                  sigmaX: _blurSigma(recipe),
                  sigmaY: _blurSigma(recipe),
                ),
                inner: ColorFilter.matrix(
                  saturationColorMatrix(recipe.saturation),
                ),
              ),
              child: content,
            )
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
        ? (recipe.borderOpacity * 0.2).clamp(0.0, 1.0)
        : recipe.borderOpacity.clamp(0.0, 1.0);
    return isDark
        ? Colors.white.withValues(alpha: alpha)
        : cs.outlineVariant.withValues(alpha: alpha);
  }

  List<BoxShadow> _shadows(bool isDark, MaterialRecipe recipe) {
    // 浅色模式零投影：磨砂面靠 tint 差异 + hairline 分层，
    // 弱影只会糊成灰雾。
    if (!isDark || recipe.shadowOpacity <= 0.001) return const [];
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: recipe.shadowOpacity),
        blurRadius: 18,
        offset: const Offset(0, 6),
      ),
    ];
  }
}

/// 程序化噪点纹理（亚克力 / 云母用）。
///
/// 固定随机种子 → 每像素稳定，不引入图片资源；1px 点阵在低不透明度下即为
/// 细微 grain。
class _NoisePainter extends CustomPainter {
  const _NoisePainter({required this.opacity, required this.isDark});

  final double opacity;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final random = math.Random(20240912);
    final count = (size.width * size.height / 24).clamp(0, 4000).toInt();
    final baseColor = isDark ? Colors.white : Colors.black;
    for (var i = 0; i < count; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      final alpha = opacity * (0.35 + random.nextDouble() * 0.65);
      paint.color = baseColor.withValues(alpha: alpha);
      canvas.drawRect(Rect.fromLTWH(x, y, 1, 1), paint);
    }
  }

  @override
  bool shouldRepaint(_NoisePainter oldDelegate) =>
      oldDelegate.opacity != opacity || oldDelegate.isDark != isDark;
}
