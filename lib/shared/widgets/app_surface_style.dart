import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';

import '../../core/theme/glass_refraction.dart';
import '../../core/theme/surface_material.dart';

/// Apple 风格平色卡面配方（浅 / 深双模式，零高光、零 BackdropFilter）。
///
/// 视觉做减法：卡面只剩「平色填充 + 深色柔影」，不做描边——重复的
/// hairline 圆角矩形框线是视觉疲劳的主要来源；分层交给色调对比与柔影
/// 完成，Dock 这类真正需要材质层次的玻璃容器另行处理：
///
/// 1. **平色填充**——深色 `surfaceContainerLow`、浅色
///    `surfaceContainerLowest`；玻璃开启时替换为同色半透明 tint，
///    透明度由调用方按档位换算后经 `tintAlpha` 传入。
/// 2. **落底投影（[appSurfaceShadows]）**——仅深色保留单层环境影，
///    浅色零投影（白卡与中性灰 scaffold 的色调对比已经完成分层）。
///
/// 使用方式：装饰直接作用在卡面 Container 上（见 `AppCard` 与
/// `AppTileSurface`）。

/// 卡面平色填充：玻璃开启时为半透明 tint，透明度由调用方按档位换算。
Color appSurfaceColor({
  required ColorScheme cs,
  required bool isDark,
  required bool glassEnabled,
  required double tintAlpha,
}) {
  final base = isDark ? cs.surfaceContainerLow : cs.surfaceContainerLowest;
  return glassEnabled ? base.withValues(alpha: tintAlpha) : base;
}

/// 平色卡面装饰：无描边的 flat 填充，玻璃开启时为半透明 tint。
ShapeDecoration appSurfaceDecoration({
  required ColorScheme cs,
  required bool isDark,
  required bool glassEnabled,
  required BorderRadius borderRadius,
  required double tintAlpha,
}) {
  return ShapeDecoration(
    color: appSurfaceColor(
      cs: cs,
      isDark: isDark,
      glassEnabled: glassEnabled,
      tintAlpha: tintAlpha,
    ),
    shape: RoundedSuperellipseBorder(borderRadius: borderRadius),
  );
}

/// 落底投影：仅深色模式保留单层环境影；浅色模式零投影——白卡与中性灰
/// scaffold 的色调对比已经完成分层，弱投影只会渲染成一圈脏灰雾
/// （Apple 分组列表同款做法）。
List<BoxShadow> appSurfaceShadows({required bool isDark}) {
  if (isDark) {
    return const [
      BoxShadow(color: Color(0x47000000), blurRadius: 16, offset: Offset(0, 6)),
    ];
  }
  return const [];
}

/// 磨砂填充：在表面底色上叠一层乳白「雾」再按 [alpha] 半透明，
/// 模拟磨砂玻璃的漫反射泛白（浅色更明显，深色只带一点灰雾）。
Color frostedFillColor({
  required Color base,
  required bool isDark,
  required double alpha,
}) {
  final veil = Colors.white.withValues(alpha: isDark ? 0.06 : 0.18);
  return Color.alphaBlend(veil, base).withValues(alpha: alpha);
}

/// 磨砂描边：浅色用白色亮边（玻璃切边受光），深色沿用淡白发丝线。
Color frostedBorderColor({
  required MaterialRecipe recipe,
  required bool isDark,
  double scale = 1.0,
}) {
  final alpha = isDark ? recipe.borderOpacity * 0.2 * scale : 0.60 * scale;
  return Colors.white.withValues(alpha: alpha.clamp(0.0, 1.0));
}

/// 亚克力背景滤镜：配方饱和度为 1 时只做模糊，省掉一层颜色矩阵合成；
/// 亚克力磁贴 / 顶栏 / dock 共用，组件不要各自拼 [ImageFilterConfig]。
///
/// 提饱和只在非 bounded 时叠加：Impeller（Android OpenGLES）下 bounded 模糊
/// 与颜色矩阵合成会在底边上方画出紫/青色横条（见 `AppTileSurface` 注释），
/// bounded 的顶栏 / 玻璃容器因此只做模糊。
ImageFilterConfig acrylicBackdropFilter(
  MaterialRecipe recipe, {
  required double sigma,
  required bool bounded,
}) {
  final blur = ImageFilterConfig.blur(
    sigmaX: sigma,
    sigmaY: sigma,
    bounded: bounded,
  );
  if (bounded || !recipe.adjustsSaturation) return blur;
  return ImageFilterConfig.compose(
    outer: blur,
    inner: ImageFilterConfig(
      ColorFilter.matrix(saturationColorMatrix(recipe.saturation)),
    ),
  );
}

/// 把折射层叠到模糊层之上：`compose` 的语义是 `outer(inner(source))`，
/// 所以折射必须是 `outer`、模糊是 `inner`，即「先模糊背景，再让玻璃曲面
/// 去折射已经模糊过的背景」。
///
/// 顺序写反（`outer: blur`）时 sigma≈19 的高斯会跑在折射之后，把整条
/// 18dp 边缘折射带、1.6dp 色散与窄镜面高光一起糊平——肉眼只剩普通磨砂，
/// 液态玻璃完全看不出来。
///
/// [refraction] 为 null（shader 未预载 / 非 Impeller 后端）时原样退回纯磨砂。
ImageFilterConfig composeLiquidGlassLayers({
  required ImageFilterConfig blur,
  ImageFilterConfig? refraction,
}) {
  if (refraction == null) return blur;
  return ImageFilterConfig.compose(outer: refraction, inner: blur);
}

/// 液态玻璃专用：模糊 → 液态玻璃边缘折射 → 色散。
///
/// 传入 [boundsHolder]（由 `LiquidGlassBoundsTracker` 在绘制前写入）时，
/// 每次 `resolve` 按真实屏幕坐标与缩放比构造 `u_bounds`，确保 Dock 与滚动卡片的
/// 边缘 SDF 与屏幕坐标严格对齐；shader 不可用时退回纯磨砂。
ImageFilterConfig liquidGlassBackdropFilter({
  required MaterialRecipe recipe,
  required double sigma,
  required double radius,
  required double devicePixelRatio,
  LiquidGlassBoundsHolder? boundsHolder,
}) {
  // 不用 bounded：Impeller 下 bounded 模糊与外层 ImageFilter（此处为 shader）
  // compose 时会把卡片底部区域裁成黑块；外层已有 ClipRRect 且 shader 自身
  // 按 u_bounds 夹紧采样范围，不会溢出卡面。
  final blur = acrylicBackdropFilter(recipe, sigma: sigma, bounded: false);
  if (boundsHolder == null) {
    return composeLiquidGlassLayers(
      blur: blur,
      refraction: LiquidGlass.filterConfig(
        radius: radius,
        devicePixelRatio: devicePixelRatio,
      ),
    );
  }
  return _LiquidGlassImageFilterConfig(
    blur: blur,
    radius: radius,
    devicePixelRatio: devicePixelRatio,
    boundsHolder: boundsHolder,
  );
}

class _LiquidGlassImageFilterConfig implements ImageFilterConfig {
  const _LiquidGlassImageFilterConfig({
    required this.blur,
    required this.radius,
    required this.devicePixelRatio,
    required this.boundsHolder,
  });

  final ImageFilterConfig blur;
  final double radius;
  final double devicePixelRatio;
  final LiquidGlassBoundsHolder boundsHolder;

  @override
  ui.ImageFilter? get filter => null;

  @override
  ui.ImageFilter resolve(ImageFilterContext context) {
    final innerBlur = blur.resolve(context);
    final globalRect = boundsHolder.globalRect;
    final localSize = boundsHolder.localSize;
    final scale =
        (globalRect != null && localSize != null && localSize.width > 0)
        ? (globalRect.width / localSize.width)
        : 1.0;
    final cached = boundsHolder.lookup(
      globalRect: globalRect,
      localBounds: context.bounds,
      radius: radius,
      scale: scale,
      dpr: devicePixelRatio,
      innerBlur: innerBlur,
    );
    if (cached != null) return cached;

    final refraction = LiquidGlass.createImageFilter(
      radius: radius,
      devicePixelRatio: devicePixelRatio,
      bounds: globalRect,
      scale: scale,
    );
    if (refraction == null) return innerBlur;
    final composed = ui.ImageFilter.compose(
      outer: refraction,
      inner: innerBlur,
    );
    boundsHolder.store(
      globalRect: globalRect,
      localBounds: context.bounds,
      radius: radius,
      scale: scale,
      dpr: devicePixelRatio,
      innerBlur: innerBlur,
      composed: composed,
    );
    return composed;
  }

  @override
  String get debugShortDescription =>
      '${blur.debugShortDescription} -> liquidGlass(radius=$radius)';

  @override
  String toString() =>
      'ImageFilterConfig.compose(source -> $debugShortDescription -> result)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _LiquidGlassImageFilterConfig &&
          other.blur == blur &&
          other.radius == radius &&
          other.devicePixelRatio == devicePixelRatio &&
          identical(other.boundsHolder, boundsHolder);

  @override
  int get hashCode => Object.hash(blur, radius, devicePixelRatio, boundsHolder);
}
