import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/core/theme/surface_material.dart';

import '../../helpers/test_setup.dart';

void main() {
  setUp(() async {
    await resetTestEnvironment();
  });

  group('sigmaFor 模糊强度派生（单一来源）', () {
    test('默认 blurSigma=14 时三档取值与历史硬编码一致', () {
      final style = GlassStyleController.instance;
      expect(style.blurSigma.value, 14);

      expect(style.sigmaFor(GlassTier.card), 14);
      expect(style.sigmaFor(GlassTier.nav), 24);
      expect(style.sigmaFor(GlassTier.overlay), 30);
    });

    test('card 档 1:1 跟随滑条，nav/overlay 按偏移派生', () async {
      final style = GlassStyleController.instance;
      await style.setBlurSigma(20);

      expect(style.sigmaFor(GlassTier.card), 20);
      expect(style.sigmaFor(GlassTier.nav), 30);
      expect(style.sigmaFor(GlassTier.overlay), 36);
    });

    test('nav/overlay 不低于各自下限', () async {
      final style = GlassStyleController.instance;
      await style.setBlurSigma(0);

      expect(style.sigmaFor(GlassTier.card), 0);
      expect(style.sigmaFor(GlassTier.nav), 16);
      expect(style.sigmaFor(GlassTier.overlay), 22);
    });

    test('nav/overlay 不超过各自上限', () async {
      final style = GlassStyleController.instance;
      await style.setBlurSigma(30);

      expect(style.sigmaFor(GlassTier.nav), 30);
      expect(style.sigmaFor(GlassTier.overlay), 36);
    });
  });

  group('shouldBlur 全局模糊闸', () {
    test('默认开启', () {
      expect(GlassStyleController.instance.shouldBlur(), isTrue);
    });

    test('总开关关闭后为 false', () async {
      await GlassStyleController.instance.setEnabled(false);
      expect(GlassStyleController.instance.shouldBlur(), isFalse);
    });

    test('模糊强度拉到 0 后为 false（滑条 0 = 关模糊）', () async {
      await GlassStyleController.instance.setBlurSigma(0);
      expect(GlassStyleController.instance.shouldBlur(), isFalse);
    });
  });

  group('亚克力单一开关', () {
    test('默认开启且为亚克力', () {
      final c = GlassStyleController.instance;
      expect(c.enabled.value, isTrue);
      expect(c.materialStyle.value, SurfaceMaterialStyle.acrylic);
    });

    test('关闭为实色，重新开启回到亚克力', () async {
      final c = GlassStyleController.instance;
      await c.setEnabled(false);
      expect(c.materialStyle.value, SurfaceMaterialStyle.solid);
      await c.setEnabled(true);
      expect(c.materialStyle.value, SurfaceMaterialStyle.acrylic);
    });
  });
}
