import 'dart:math' as math;

/// 表面材质风格。
///
/// 应用只有两种材质：[acrylic]（真实背景模糊 + 半透明填充 + hairline）与
/// [solid]（实色，无 BackdropFilter，仅测试路径使用）。由统一的 [MaterialRecipe]
/// 驱动，组件不得各自实现 BackdropFilter / tint / border / shadow。
enum SurfaceMaterialStyle {
  /// 不透明表面，最省 GPU。
  solid,

  /// 背景模糊 + tint。
  acrylic,
}

/// 表面填充 tint 不透明度（0.2-1.0）。曾是用户滑条，现固定为默认值；
/// 平色卡面（`AppCard` / `PlainListGroup` / `AppTileSurface`）与亚克力配方
/// 共用这一个来源。
const double kSurfaceTintOpacity = 0.84;

/// 卡片档模糊强度基准（0-30）。曾是用户滑条，现固定为默认值，亚克力配方
/// 在此基础上派生。
const double kSurfaceBlurBase = 14;

/// 材质配方：把「风格」翻译成渲染参数。
///
/// 参数含义：
/// * [blurSigma] 背景模糊强度，0 表示不创建 BackdropFilter；
/// * [surfaceOpacity] 表面平色填充不透明度；
/// * [borderOpacity] 边缘描边不透明度；
/// * [shadowOpacity] 投影不透明度；
/// * [saturation] 背景饱和倍数；1 表示不做颜色矩阵（只模糊）。
///
/// 视觉减负：曾叠加的程序化颗粒（每次重绘生成上千随机点）与 1.12 倍提饱和
/// 已移除——颗粒在小屏上读作「脏」，提饱和让壁纸透到卡面上更花；两者还各
/// 占一次合成/绘制开销。
class MaterialRecipe {
  const MaterialRecipe._({
    required this.style,
    required this.blurSigma,
    required this.surfaceOpacity,
    required this.borderOpacity,
    required this.shadowOpacity,
    required this.saturation,
  });

  final SurfaceMaterialStyle style;
  final double blurSigma;
  final double surfaceOpacity;
  final double borderOpacity;
  final double shadowOpacity;
  final double saturation;

  bool get usesBackdropBlur => blurSigma > 0.5;
  bool get adjustsSaturation => (saturation - 1).abs() > 0.001;

  static const MaterialRecipe _solid = MaterialRecipe._(
    style: SurfaceMaterialStyle.solid,
    blurSigma: 0,
    surfaceOpacity: 1,
    borderOpacity: 0.5,
    shadowOpacity: 0,
    saturation: 1,
  );

  static const MaterialRecipe _acrylic = MaterialRecipe._(
    style: SurfaceMaterialStyle.acrylic,
    blurSigma: kSurfaceBlurBase * 1.35 + 4,
    // 填充必须保持明显半透明：实时模糊由 BackdropFilter 提供，若填充
    // 接近不透明会把模糊完全盖住，视觉上退化成实色。
    surfaceOpacity: kSurfaceTintOpacity * 0.70,
    borderOpacity: 0.30,
    shadowOpacity: 0.14,
    saturation: 1,
  );

  /// 取风格对应的配方。
  static MaterialRecipe resolve(SurfaceMaterialStyle style) {
    switch (style) {
      case SurfaceMaterialStyle.solid:
        return _solid;
      case SurfaceMaterialStyle.acrylic:
        return _acrylic;
    }
  }
}

/// 提饱和 ColorFilter 矩阵。
List<double> saturationColorMatrix(double saturation) {
  final s = math.max(0.0, saturation);
  const lumR = 0.2126;
  const lumG = 0.7152;
  const lumB = 0.0722;
  final sr = (1 - s) * lumR;
  final sg = (1 - s) * lumG;
  final sb = (1 - s) * lumB;
  return <double>[
    sr + s, sg, sb, 0, 0, //
    sr, sg + s, sb, 0, 0, //
    sr, sg, sb + s, 0, 0, //
    0, 0, 0, 1, 0,
  ];
}
