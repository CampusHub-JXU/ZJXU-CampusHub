import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/glass_refraction.dart';
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
    this.liquid = false,
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

  /// 是否启用 Dock 同款液态玻璃效果（折射 + 色散 + 边缘高光 + 挖空悬浮影）。
  /// [GlassTier.nav] 默认启用；其余档位默认关闭以免增加密集网格开销。
  final bool liquid;
  final VoidCallback? onTap;

  bool get _wantsLiquid => tier == GlassTier.nav || liquid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final radius = borderRadius ?? AppRadius.cardBorder;
    final style = GlassStyleController.instance;

    // 液态玻璃层还要等 shader 就绪：冷启动首帧 `preload()` 往往还没跑完，
    // 只听 `surfaceChanged` 的话，shader 加载完成后不会重建出折射。
    final listenable = _wantsLiquid
        ? Listenable.merge(<Listenable>[
            style.surfaceChanged,
            LiquidGlass.ready,
          ])
        : style.surfaceChanged;

    return ListenableBuilder(
      listenable: listenable,
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
    final wantsLiquid = _wantsLiquid;
    // 液态玻璃启用且 shader 就绪（否则退回纯磨砂）。
    final liquidGlass = useBlur && wantsLiquid && LiquidGlass.isReady;
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
                alpha: _fillAlpha(
                  recipe,
                  wantsLiquid: wantsLiquid,
                  liquidGlass: liquidGlass,
                  isDark: isDark,
                ),
              )
            : baseSurface,
    };

    final borderColor = _borderColor(
      recipe,
      isDark,
      cs,
      liquidGlass: liquidGlass,
    );
    // 液态玻璃面（acrylic）沿轮廓画方向性液态玻璃边缘高光描边，此时收起
    // ShapeDecoration 的整圈 hairline，避免双框；solid 退化仍走普通描边。
    final liquidEdgeStroke =
        wantsLiquid && useBlur && recipe.style == SurfaceMaterialStyle.acrylic;

    final paddedChild = padding == null
        ? child
        : Padding(padding: padding!, child: child);
    final innerContent = onTap == null
        ? paddedChild
        : Material(
            color: Colors.transparent,
            child: InkWell(
              customBorder: RoundedSuperellipseBorder(borderRadius: radius),
              onTap: onTap,
              child: paddedChild,
            ),
          );

    final content = Container(
      width: width,
      height: height,
      alignment: alignment,
      decoration: ShapeDecoration(
        color: fillColor,
        image: grain && useBlur && recipe.style == SurfaceMaterialStyle.acrylic
            ? frostGrainImage(isDark: isDark)
            : null,
        shadows: useBlur && !liquidEdgeStroke ? _shadows(isDark, recipe) : null,
        shape: RoundedSuperellipseBorder(
          borderRadius: radius,
          side: liquidEdgeStroke
              ? BorderSide.none
              : BorderSide(color: borderColor, width: isDark ? 0.8 : 1.0),
        ),
      ),
      child: innerContent,
    );

    // 关键约束：
    // 1. ClipRRect 必须严格处于 BackdropFilter 祖先位置；
    // 2. 局部受限采样（bounded blur）避免边缘溢色（edge bleed）。
    // 3. 液态玻璃面在模糊层之上叠折射与色散（Impeller 不可用时退回纯磨砂）。
    Widget layer = content;
    if (useBlur) {
      final sigma = _blurSigma(
        recipe,
        wantsLiquid: wantsLiquid,
        liquidGlass: liquidGlass,
      );
      final filtered = wantsLiquid
          ? _LiquidGlassFilterLayer(
              recipe: recipe,
              sigma: sigma,
              radius: radius.topLeft.x,
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
              child: content,
            )
          : BackdropFilter(
              filterConfig: acrylicBackdropFilter(
                recipe,
                sigma: sigma,
                bounded: true,
              ),
              child: content,
            );
      layer = liquidEdgeStroke
          // 高光描边与 BackdropFilter 同级（同在 ClipRRect 内），保证
          // BackdropFilter 内部没有任何 CustomPaint（防噪点回归守卫）。
          ? Stack(
              fit: StackFit.passthrough,
              children: [
                filtered,
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      foregroundPainter: _NavLiquidEdgePainter(
                        borderRadius: radius,
                        isDark: isDark,
                      ),
                    ),
                  ),
                ),
              ],
            )
          : filtered;
    }
    Widget clipped = ClipRRect(borderRadius: radius, child: layer);
    // 液态玻璃悬浮影必须画在 ClipRRect 外层：写在被裁层内部会被整圈裁掉，
    // 白底上没有「浮起」的底影，亮高光描边也失去反差底。
    // 用 CustomPaint + evenOdd 挖空玻璃轮廓，阴影只落在轮廓外围环带。
    if (liquidEdgeStroke) {
      clipped = CustomPaint(
        painter: _NavOuterShadowPainter(
          borderRadius: radius,
          color: Colors.black.withValues(
            alpha: isDark ? recipe.shadowOpacity : 0.08,
          ),
        ),
        child: clipped,
      );
    }

    return clipped;
  }

  /// 模糊强度：按配方再乘档位系数，保证 nav/overlay 仍略重于卡片。
  ///
  /// 液态玻璃分两条路径：
  /// * shader 就绪时系数收到 0.15（σ≈2.8）：折射只弯折「已经模糊过」的背景，
  ///   σ 越大位移后的色块与红蓝边带对比越平。σ≈2.8 既保住玻璃的柔化感，
  ///   又让背后的文字与彩色边缘在边带里保有清晰弯折与色散。
  /// * shader 未就绪退回纯磨砂时仍是 1.0（σ≈18.8）：没有折射层，磨砂自己
  ///   得撑起材质感，再压 σ 会显得单薄发涩。
  double _blurSigma(
    MaterialRecipe recipe, {
    bool wantsLiquid = false,
    bool liquidGlass = false,
  }) {
    if (wantsLiquid) {
      final factor = liquidGlass ? 0.15 : 1.0;
      return (recipe.blurSigma * factor).clamp(0.0, 44.0);
    }
    final factor = switch (tier) {
      GlassTier.card => 1.0,
      GlassTier.nav => liquidGlass ? 0.15 : 1.0,
      GlassTier.overlay => 1.4,
    };
    return (recipe.blurSigma * factor).clamp(0.0, 44.0);
  }

  /// 填充不透明度：配方值并按档位加一点保底，避免底栏/弹层过透。
  ///
  /// 液态玻璃面反而要更透：材质感来自折射 + 边缘色散 + 高光描边，高遮罩
  /// 会把弯曲与色散吃掉退回塑料片。浅色收在 0.18–0.26（清亮不发灰）、
  /// 深色收在 0.10–0.18（深琉璃不泛白雾）。
  double _fillAlpha(
    MaterialRecipe recipe, {
    required bool wantsLiquid,
    required bool liquidGlass,
    bool isDark = false,
  }) {
    final base = recipe.surfaceOpacity;
    if (wantsLiquid) {
      if (liquidGlass) {
        return isDark
            ? (base * 0.32).clamp(0.10, 0.18)
            : (base * 0.48).clamp(0.18, 0.26);
      }
      return (base * 0.5).clamp(0.18, 0.26);
    }
    if (tier == GlassTier.card) return base;
    return (base + 0.15).clamp(0.0, 1.0);
  }

  Color _borderColor(
    MaterialRecipe recipe,
    bool isDark,
    ColorScheme cs, {
    bool liquidGlass = false,
  }) {
    if (recipe.style == SurfaceMaterialStyle.solid) {
      return cs.outlineVariant.withValues(alpha: recipe.borderOpacity);
    }
    // 液态玻璃生效时把白描边压淡：α0.60 的整圈亮边会盖住 shader 画出的
    // 高光带与边缘 AO，玻璃曲面就读不出来了。
    return frostedBorderColor(
      recipe: recipe,
      isDark: isDark,
      scale: liquidGlass ? 0.35 : 1.0,
    );
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

/// nav 档「悬浮边影」：画在 [ClipRRect] 外层的挖空外投影。
///
/// 不用 `DecoratedBox(BoxDecoration(boxShadow:))`：BoxShadow 的阴影矩形
/// 铺在整个盒子底下且内部不挖空，半透明黑影会直接从未遮挡的玻璃内部
/// 透出来，浅色 Dock 被染成一条脏灰。这里用 [PathFillType.evenOdd]：
/// 一个足够大的外框矩形减去玻璃的超椭圆轮廓，clip 之后阴影只在轮廓
/// 外围环带可见，玻璃内部 100% 干净透亮。
class _NavOuterShadowPainter extends CustomPainter {
  _NavOuterShadowPainter({required this.borderRadius, required this.color});

  final BorderRadius borderRadius;
  final Color color;

  /// 视觉模糊半径 18，换算 MaskFilter sigma ≈ radius * 0.57735 + 0.5。
  static const double _sigma = 18 * 0.57735 + 0.5;

  /// 阴影向下偏移（dp），与原 `BoxShadow(0, 5)` 一致。
  static const double _offsetY = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final clip = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect.inflate(128))
      ..addRSuperellipse(borderRadius.toRSuperellipse(rect));
    canvas.save();
    canvas.clipPath(clip);
    canvas.drawPath(
      Path()..addRSuperellipse(
        borderRadius.toRSuperellipse(rect.shift(const Offset(0, _offsetY))),
      ),
      Paint()
        ..color = color
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, _sigma),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_NavOuterShadowPainter old) =>
      old.borderRadius != borderRadius || old.color != color;
}

/// nav 档液态玻璃边缘高光描边。
///
/// 沿超椭圆外轮廓（略内缩 0.7dp，避免描边一半悬在裁剪边外）画两层细线：
/// 1. 外缘对比细线（0.6dp）——浅色用极淡黑、深色用淡白，先把轮廓「勾」出来；
/// 2. 方向性镜面高光（1.35dp）——左上→右下对角线性渐变，模拟玻璃切边受光
///    的各向异性反射。浅 / 深两套 alpha 曲线，保证白底与黑底上轮廓都清晰。
class _NavLiquidEdgePainter extends CustomPainter {
  _NavLiquidEdgePainter({required this.borderRadius, required this.isDark});

  final BorderRadius borderRadius;
  final bool isDark;

  /// 描边路径相对外轮廓的内缩量：高光半宽 0.675dp 全部落在裁剪区内。
  static const double _edgeInset = 0.7;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRSuperellipse(
        borderRadius.toRSuperellipse(Offset.zero & size).deflate(_edgeInset),
      );

    final contrast = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = isDark
          ? Colors.white.withValues(alpha: 0.12)
          : Colors.black.withValues(alpha: 0.06);
    canvas.drawPath(path, contrast);

    final bounds = Offset.zero & size;
    final specular = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        stops: const [0.0, 0.22, 0.50, 0.78, 1.0],
        colors: isDark
            ? [
                Colors.white.withValues(alpha: 0.72),
                Colors.white.withValues(alpha: 0.22),
                Colors.white.withValues(alpha: 0.08),
                Colors.white.withValues(alpha: 0.20),
                Colors.white.withValues(alpha: 0.44),
              ]
            : [
                Colors.white.withValues(alpha: 0.96),
                Colors.white.withValues(alpha: 0.38),
                Colors.white.withValues(alpha: 0.16),
                Colors.white.withValues(alpha: 0.42),
                Colors.white.withValues(alpha: 0.82),
              ],
      ).createShader(bounds);
    canvas.drawPath(path, specular);
  }

  @override
  bool shouldRepaint(_NavLiquidEdgePainter old) =>
      old.borderRadius != borderRadius || old.isDark != isDark;
}

/// 持有液态玻璃容器的屏幕矩形槽，包一层 [LiquidGlassBoundsTracker] 并在
/// 滚动时触发 [BackdropFilter] 重绘，保证 `u_bounds` 永远匹配当前屏幕位置。
class _LiquidGlassFilterLayer extends StatefulWidget {
  const _LiquidGlassFilterLayer({
    required this.recipe,
    required this.sigma,
    required this.radius,
    required this.devicePixelRatio,
    required this.child,
  });

  final MaterialRecipe recipe;
  final double sigma;
  final double radius;
  final double devicePixelRatio;
  final Widget child;

  @override
  State<_LiquidGlassFilterLayer> createState() =>
      _LiquidGlassFilterLayerState();
}

class _LiquidGlassFilterLayerState extends State<_LiquidGlassFilterLayer> {
  final _boundsHolder = LiquidGlassBoundsHolder();

  @override
  void dispose() {
    _boundsHolder.invalidateCache();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scrollPosition = Scrollable.maybeOf(context)?.position;
    return LiquidGlassBoundsTracker(
      holder: _boundsHolder,
      scrollPosition: scrollPosition,
      child: BackdropFilter(
        filterConfig: liquidGlassBackdropFilter(
          recipe: widget.recipe,
          sigma: widget.sigma,
          radius: widget.radius,
          devicePixelRatio: widget.devicePixelRatio,
          boundsHolder: _boundsHolder,
        ),
        child: widget.child,
      ),
    );
  }
}
