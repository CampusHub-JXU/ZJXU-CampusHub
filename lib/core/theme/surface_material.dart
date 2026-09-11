import 'dart:math' as math;

/// 表面材质风格（PRD 0.7.0 §20）。
///
/// 由统一的 [MaterialRecipe] 驱动，组件不得各自实现 BackdropFilter / tint /
/// border / shadow。
enum SurfaceMaterialStyle {
  solid(label: '实色', description: '不透明表面，最省 GPU'),
  glass(label: '玻璃', description: '明显模糊、低 tint，背景透出'),
  acrylic(label: '亚克力', description: '更强模糊与 tint，带细微噪点'),
  mica(label: '云母', description: '低模糊、背景色调采样，适合大面积');

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

/// 材质配方：把「风格」翻译成渲染参数。
///
/// 参数含义（PRD §20）：
/// * [blurSigma] 背景模糊强度，0 表示不创建 BackdropFilter；
/// * [surfaceOpacity] 表面平色填充不透明度；
/// * [tintOpacity] 额外色调叠加不透明度；
/// * [noiseOpacity] 噪点纹理不透明度（亚克力/云母 > 0）；
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
  /// 亚克力/云母在同两个输入上做风格化偏移，保证滑条对所有材质仍有意义。
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
          borderOpacity: 0.7,
          highlightOpacity: 0.26,
          shadowOpacity: 0.2,
          saturation: 1.06,
        );
      case SurfaceMaterialStyle.acrylic:
        return MaterialRecipe(
          style: SurfaceMaterialStyle.acrylic,
          blurSigma: (blurBase * 1.35 + 4).clamp(6.0, 44.0),
          surfaceOpacity: (tintBase + 0.10).clamp(0.2, 1.0),
          tintOpacity: (tintBase * 0.72).clamp(0.1, 0.8),
          noiseOpacity: 0.06,
          borderOpacity: 0.42,
          highlightOpacity: 0.12,
          shadowOpacity: 0.18,
          saturation: 1.12,
        );
      case SurfaceMaterialStyle.mica:
        return MaterialRecipe(
          style: SurfaceMaterialStyle.mica,
          blurSigma: (blurBase * 0.4).clamp(0.0, 12.0),
          surfaceOpacity: (tintBase + 0.28).clamp(0.3, 1.0),
          tintOpacity: (tintBase * 0.45).clamp(0.05, 0.6),
          noiseOpacity: 0.03,
          borderOpacity: 0.28,
          highlightOpacity: 0.08,
          shadowOpacity: 0.12,
          saturation: 1.04,
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
