import 'dart:math' as math;

/// 表面材质风格（PRD 0.7.0 §20）。
///
/// 由统一的 [MaterialRecipe] 驱动，组件不得各自实现 BackdropFilter / tint /
/// border / shadow。
enum SurfaceMaterialStyle {
  solid(label: '实色', description: '不透明表面，最省 GPU'),
  glass(label: '玻璃', description: '明显模糊、低 tint，背景透出'),
  acrylic(label: '亚克力', description: '更强模糊与 tint，带细微噪点'),
  mica(label: '云母', description: '不透明稳定表面，主题色调采样，无实时模糊');

  const SurfaceMaterialStyle({required this.label, required this.description});

  final String label;
  final String description;

  static SurfaceMaterialStyle fromName(String? name) {
    return SurfaceMaterialStyle.values.firstWhere(
      (style) => style.name == name,
      orElse: () => SurfaceMaterialStyle.glass,
    );
  }
}

/// 表面材质类型别名，对齐统一材质语义。
typedef MaterialSurfaceType = SurfaceMaterialStyle;

/// 材质配方：把「风格」翻译成渲染参数。
///
/// 参数含义（PRD §20）：
/// * [blurSigma] 背景模糊强度，0 表示不创建 BackdropFilter；
/// * [surfaceOpacity] 表面平色填充不透明度；
/// * [tintOpacity] 额外色调叠加不透明度；
/// * [noiseOpacity] 噪点纹理不透明度（仅亚克力 > 0）；
/// * [borderOpacity] 边缘描边不透明度；
/// * [highlightOpacity] 顶部高光不透明度；
/// * [shadowOpacity] 投影不透明度；
/// * [saturation] 背景提饱和倍数。
class MaterialRecipe {
  const MaterialRecipe({
    required this.style,
    required this.blurSigma,
    required this.surfaceOpacity,
    required this.tintOpacity,
    required this.noiseOpacity,
    required this.borderOpacity,
    required this.highlightOpacity,
    required this.shadowOpacity,
    required this.saturation,
  });

  final SurfaceMaterialStyle style;
  final double blurSigma;
  final double surfaceOpacity;
  final double tintOpacity;
  final double noiseOpacity;
  final double borderOpacity;
  final double highlightOpacity;
  final double shadowOpacity;
  final double saturation;

  bool get usesBackdropBlur => blurSigma > 0.5;
  bool get hasNoise => noiseOpacity > 0.001;
  bool get hasHighlight => highlightOpacity > 0.001;

  /// 由用户滑条基准（模糊强度 / 透明度）与风格派生配方。
  ///
  /// 玻璃风格与历史行为一致：模糊强度 1:1 跟随滑条、透明度跟随 tint 滑条。
  /// 亚克力在同两个输入上做风格化偏移；云母无实时模糊，填充恒为不透明，
  /// tint 滑条只影响其色调叠加强度。
  static MaterialRecipe resolve(
    SurfaceMaterialStyle style, {
    required double blurBase,
    required double tintBase,
  }) {
    switch (style) {
      case SurfaceMaterialStyle.solid:
        return const MaterialRecipe(
          style: SurfaceMaterialStyle.solid,
          blurSigma: 0,
          surfaceOpacity: 1,
          tintOpacity: 0,
          noiseOpacity: 0,
          borderOpacity: 0.5,
          highlightOpacity: 0,
          shadowOpacity: 0,
          saturation: 1,
        );
      case SurfaceMaterialStyle.glass:
        return MaterialRecipe(
          style: SurfaceMaterialStyle.glass,
          blurSigma: blurBase.clamp(0.0, 40.0),
          surfaceOpacity: tintBase.clamp(0.2, 1.0),
          tintOpacity: (tintBase * 0.22).clamp(0.0, 0.4),
          noiseOpacity: 0,
          borderOpacity: 0.35,
          highlightOpacity: 0,
          shadowOpacity: 0.10,
          saturation: 1.06,
        );
      case SurfaceMaterialStyle.acrylic:
        return MaterialRecipe(
          style: SurfaceMaterialStyle.acrylic,
          blurSigma: (blurBase * 1.35 + 4).clamp(6.0, 44.0),
          // 填充必须保持明显半透明：实时模糊由 BackdropFilter 提供，若填充
          // 接近不透明会把模糊完全盖住，视觉上退化成云母。
          surfaceOpacity: (tintBase * 0.70).clamp(0.40, 0.72),
          tintOpacity: (tintBase * 0.68).clamp(0.1, 0.8),
          noiseOpacity: 0.04,
          borderOpacity: 0.30,
          highlightOpacity: 0,
          shadowOpacity: 0.14,
          saturation: 1.12,
        );
      case SurfaceMaterialStyle.mica:
        // 云母永不创建 BackdropFilter，填充必须完全不透明：否则未模糊的
        // 背景会从半透明 tint 下透出，形成「脏透底」。
        return MaterialRecipe(
          style: SurfaceMaterialStyle.mica,
          blurSigma: 0,
          surfaceOpacity: 1,
          tintOpacity: (tintBase * 0.35).clamp(0.08, 0.5),
          noiseOpacity: 0,
          borderOpacity: 0.25,
          highlightOpacity: 0,
          shadowOpacity: 0.08,
          saturation: 1.0,
        );
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
