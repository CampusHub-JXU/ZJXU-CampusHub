import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/surface_material.dart';

void main() {
  group('MaterialRecipe.resolve 材质差异', () {
    test('只有实色与亚克力两种风格', () {
      expect(SurfaceMaterialStyle.values, [
        SurfaceMaterialStyle.solid,
        SurfaceMaterialStyle.acrylic,
      ]);
    });

    test('实色不模糊且完全不透明', () {
      final recipe = MaterialRecipe.resolve(SurfaceMaterialStyle.solid);
      expect(recipe.style, SurfaceMaterialStyle.solid);
      expect(recipe.usesBackdropBlur, isFalse);
      expect(recipe.blurSigma, 0.0);
      expect(recipe.surfaceOpacity, 1.0);
      expect(recipe.adjustsSaturation, isFalse);
    });

    test('亚克力（磨砂）：重模糊、明显半透明、无颗粒、轻度提饱和', () {
      final recipe = MaterialRecipe.resolve(SurfaceMaterialStyle.acrylic);
      expect(recipe.style, SurfaceMaterialStyle.acrylic);
      expect(recipe.usesBackdropBlur, isTrue);
      expect(recipe.blurSigma, closeTo(kSurfaceBlurBase * 1.2 + 2, 1e-9));
      // 顶栏 / overlay 档会再乘 1.2 / 1.4，仍须落在 44 夹紧上限内的合理区间。
      expect(recipe.blurSigma, lessThanOrEqualTo(44.0));
      expect(recipe.surfaceOpacity, lessThan(1.0));
      expect(recipe.surfaceOpacity, greaterThanOrEqualTo(0.40));
      // 提饱和仅非 bounded 滤镜生效（见 acrylicBackdropFilter）。
      expect(recipe.adjustsSaturation, isTrue);
      expect(recipe.saturation, inInclusiveRange(1.0, 1.4));
    });

    test('各风格均产出有限非负参数', () {
      for (final style in SurfaceMaterialStyle.values) {
        final recipe = MaterialRecipe.resolve(style);
        for (final value in [
          recipe.blurSigma,
          recipe.surfaceOpacity,
          recipe.borderOpacity,
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
