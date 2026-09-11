import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/surface_material.dart';

void main() {
  group('MaterialRecipe.resolve 材质差异（PRD §21-23）', () {
    MaterialRecipe resolve(SurfaceMaterialStyle style) =>
        MaterialRecipe.resolve(style, blurBase: 14, tintBase: 0.84);

    test('实色不模糊且完全不透明', () {
      final recipe = resolve(SurfaceMaterialStyle.solid);
      expect(recipe.usesBackdropBlur, isFalse);
      expect(recipe.surfaceOpacity, 1.0);
      expect(recipe.hasNoise, isFalse);
    });

    test('玻璃明显模糊、低 tint、有边缘高光', () {
      final recipe = resolve(SurfaceMaterialStyle.glass);
      expect(recipe.usesBackdropBlur, isTrue);
      expect(recipe.blurSigma, greaterThan(6));
      expect(recipe.tintOpacity, lessThan(0.4));
      expect(recipe.hasHighlight, isTrue);
      expect(recipe.hasNoise, isFalse);
    });

    test('亚克力比玻璃更强模糊、更高 tint、带噪点', () {
      final glass = resolve(SurfaceMaterialStyle.glass);
      final acrylic = resolve(SurfaceMaterialStyle.acrylic);
      expect(acrylic.blurSigma, greaterThan(glass.blurSigma));
      expect(acrylic.tintOpacity, greaterThan(glass.tintOpacity));
      expect(acrylic.hasNoise, isTrue);
    });

    test('云母低模糊、高表面不透明度、细微噪点', () {
      final glass = resolve(SurfaceMaterialStyle.glass);
      final mica = resolve(SurfaceMaterialStyle.mica);
      expect(mica.blurSigma, lessThan(glass.blurSigma));
      expect(mica.surfaceOpacity, greaterThan(glass.surfaceOpacity));
      expect(mica.hasNoise, isTrue);
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
