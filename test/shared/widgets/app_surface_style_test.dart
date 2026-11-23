import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/surface_material.dart';
import 'package:jxu_campus_hub/shared/widgets/app_surface_style.dart';

import '../../helpers/test_setup.dart';

/// Dock 液态玻璃的合成顺序回归测试。
///
/// `ImageFilterConfig.compose` 的语义是 `outer(inner(source))`：折射必须是
/// `outer`。曾经写反成 `outer: blur`，σ≈19 的高斯跑在折射之后，把 18dp
/// 边缘折射带、1.6dp 色散与窄镜面高光全部糊平，液态玻璃退化成普通磨砂。
void main() {
  setUp(() async {
    await resetTestEnvironment();
  });

  final recipe = MaterialRecipe.resolve(SurfaceMaterialStyle.acrylic);

  /// 用颜色矩阵滤镜冒充折射层：debugShortDescription 与 blur 可区分。
  ImageFilterConfig fakeRefraction() => ImageFilterConfig(
    ui.ImageFilter.matrix(
      Float64List.fromList(const <double>[
        1, 0, 0, 0, //
        0, 1, 0, 0, //
        0, 0, 1, 0, //
        0, 0, 0, 1, //
      ]),
    ),
  );

  test('折射叠在模糊之上：先模糊（inner），再折射（outer）', () {
    final blur = acrylicBackdropFilter(recipe, sigma: 18.8, bounded: true);
    final composed = composeLiquidGlassLayers(
      blur: blur,
      refraction: fakeRefraction(),
    );

    final description = composed.debugShortDescription;
    // compose 的 debug 串是「inner -> outer」，模糊必须在前。
    expect(description.indexOf('blur('), greaterThanOrEqualTo(0));
    expect(description.indexOf('matrix('), greaterThanOrEqualTo(0));
    expect(
      description.indexOf('blur('),
      lessThan(description.indexOf('matrix(')),
      reason: '模糊必须是 inner（先执行），否则折射会被高斯糊平',
    );
  });

  test('折射不可用时原样返回模糊层（不包一层 compose）', () {
    final blur = acrylicBackdropFilter(recipe, sigma: 18.8, bounded: true);

    final composed = composeLiquidGlassLayers(blur: blur);

    expect(identical(composed, blur), isTrue);
    expect(composed.debugShortDescription, contains('bounded'));
    expect(composed.debugShortDescription, isNot(contains('->')));
  });

  test('liquidGlassBackdropFilter 在 shader 未就绪时退化纯磨砂', () {
    final filter = liquidGlassBackdropFilter(
      recipe: recipe,
      sigma: 18.8,
      radius: 22,
      devicePixelRatio: 3,
    );

    expect(filter.debugShortDescription, contains('blur('));
    expect(filter.debugShortDescription, contains('clamp'));
    expect(filter.debugShortDescription, isNot(contains('shader')));
  });
}
