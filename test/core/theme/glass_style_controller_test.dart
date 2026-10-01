import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/core/theme/surface_material.dart';

import '../../helpers/test_setup.dart';

void main() {
  setUp(() async {
    await resetTestEnvironment();
  });

  group('亚克力单一开关', () {
    test('默认开启且为亚克力', () {
      final c = GlassStyleController.instance;
      expect(c.enabled.value, isTrue);
      expect(c.materialStyle, SurfaceMaterialStyle.acrylic);
    });

    test('关闭为实色，重新开启回到亚克力', () async {
      final c = GlassStyleController.instance;
      await c.setEnabled(false);
      expect(c.materialStyle, SurfaceMaterialStyle.solid);
      await c.setEnabled(true);
      expect(c.materialStyle, SurfaceMaterialStyle.acrylic);
    });
  });
}
