import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/surface_material.dart';

void main() {
  group('MaterialRecipe.resolve 材质差异与重构语义', () {
    MaterialRecipe resolve(SurfaceMaterialStyle style) =>
        MaterialRecipe.resolve(style, blurBase: 14, tintBase: 0.84);

    test('实色不模糊且完全不透明', () {
      final recipe = resolve(SurfaceMaterialStyle.solid);
      expect(recipe.usesBackdropBlur, isFalse);
      expect(recipe.blurSigma, 0.0);
      expect(recipe.surfaceOpacity, 1.0);
      expect(recipe.hasNoise, isFalse);
      expect(recipe.hasHighlight, isFalse);
    });

    test('玻璃受约束模糊、半透明 tint、无伪高光渐变', () {
      final recipe = resolve(SurfaceMaterialStyle.glass);
      expect(recipe.usesBackdropBlur, isTrue);
      expect(recipe.blurSigma, greaterThan(6));
      expect(recipe.tintOpacity, lessThan(0.4));
      expect(recipe.hasHighlight, isFalse);
      expect(recipe.hasNoise, isFalse);
      expect(recipe.shadowOpacity, lessThanOrEqualTo(0.12));
    });

    test('亚克力比玻璃更强模糊/更高 tint、明显半透明且带细微噪点', () {
      final glass = resolve(SurfaceMaterialStyle.glass);
      final acrylic = resolve(SurfaceMaterialStyle.acrylic);
      expect(acrylic.usesBackdropBlur, isTrue);
      expect(acrylic.blurSigma, greaterThan(glass.blurSigma));
      expect(acrylic.blurSigma, lessThanOrEqualTo(44.0));
      expect(acrylic.tintOpacity, greaterThan(glass.tintOpacity));
      expect(acrylic.saturation, greaterThan(glass.saturation));
      expect(acrylic.hasNoise, isTrue);
      expect(acrylic.noiseOpacity, greaterThan(0));
      expect(acrylic.noiseOpacity, lessThanOrEqualTo(0.04));
      expect(acrylic.borderOpacity, lessThanOrEqualTo(glass.borderOpacity));
      expect(acrylic.hasHighlight, isFalse);
    });

    test('亚克力与云母在模糊/透明/噪点上互斥（视觉可区分）', () {
      final acrylic = resolve(SurfaceMaterialStyle.acrylic);
      final mica = resolve(SurfaceMaterialStyle.mica);
      expect(acrylic.usesBackdropBlur, isTrue);
      expect(mica.usesBackdropBlur, isFalse);
      expect(acrylic.blurSigma, greaterThan(0));
      expect(mica.blurSigma, 0.0);
      expect(acrylic.surfaceOpacity, lessThan(1.0));
      expect(mica.surfaceOpacity, 1.0);
      expect(acrylic.hasNoise, isTrue);
      expect(mica.hasNoise, isFalse);
      expect(acrylic.noiseOpacity, greaterThan(0));
      expect(mica.noiseOpacity, 0.0);
      expect(mica.saturation, 1.0);
      expect(mica.tintOpacity, greaterThan(0));
    });

    test('云母无实时背景模糊、完全不透明且无噪点', () {
      final glass = resolve(SurfaceMaterialStyle.glass);
      final mica = resolve(SurfaceMaterialStyle.mica);
      expect(mica.usesBackdropBlur, isFalse);
      expect(mica.blurSigma, 0.0);
      expect(mica.surfaceOpacity, greaterThan(glass.surfaceOpacity));
      expect(mica.surfaceOpacity, 1.0);
      expect(mica.hasNoise, isFalse);
      expect(mica.hasHighlight, isFalse);
    });

    test('MaterialSurfaceType 为 SurfaceMaterialStyle 别名', () {
      expect(MaterialSurfaceType.values, SurfaceMaterialStyle.values);
      expect(MaterialSurfaceType.glass, SurfaceMaterialStyle.glass);
      expect(MaterialSurfaceType.acrylic, SurfaceMaterialStyle.acrylic);
      expect(MaterialSurfaceType.mica, SurfaceMaterialStyle.mica);
      expect(MaterialSurfaceType.solid, SurfaceMaterialStyle.solid);
    });

    test('四种风格均产出有限参数', () {
      for (final style in SurfaceMaterialStyle.values) {
        final recipe = resolve(style);
        for (final value in [
          recipe.blurSigma,
          recipe.surfaceOpacity,
          recipe.tintOpacity,
          recipe.noiseOpacity,
          recipe.borderOpacity,
          recipe.highlightOpacity,
          recipe.shadowOpacity,
          recipe.saturation,
        ]) {
          expect(value.isFinite, isTrue, reason: '$style 参数必须有限');
          expect(value, greaterThanOrEqualTo(0));
        }
      }
    });
  });

  test('saturationColorMatrix 恒等与提饱和', () {
    expect(saturationColorMatrix(1.0)[0], closeTo(1.0, 1e-9));
    expect(saturationColorMatrix(1.0)[1], closeTo(0.0, 1e-9));
    final boosted = saturationColorMatrix(1.5);
    expect(boosted[0], greaterThan(1.0));
    expect(boosted[1], lessThan(0.0));
    expect(saturationColorMatrix(-1.0), everyElement(greaterThanOrEqualTo(0)));
  });
}
