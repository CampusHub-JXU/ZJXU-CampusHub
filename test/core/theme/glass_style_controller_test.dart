import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/core/theme/surface_material.dart';

import '../../helpers/test_setup.dart';

void main() {
  setUp(() async {
    await resetTestEnvironment();
  });

  group('亚克力始终开启', () {
    test('默认开启且为亚克力', () {
      final c = GlassStyleController.instance;
      expect(c.enabled.value, isTrue);
      expect(c.materialStyle, SurfaceMaterialStyle.acrylic);
    });

    test('旧版本存的「关闭」不再生效，残留键被清除', () async {
      SharedPreferences.setMockInitialValues({
        'glass_material_enabled_v1': false,
      });
      final c = GlassStyleController.instance;
      c.debugMarkUnrestored();
      await c.restore();
      expect(c.enabled.value, isTrue);
      expect(c.materialStyle, SurfaceMaterialStyle.acrylic);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('glass_material_enabled_v1'), isFalse);
    });

    test('测试钩子可切到实色路径', () async {
      final c = GlassStyleController.instance;
      await c.setEnabled(false);
      expect(c.materialStyle, SurfaceMaterialStyle.solid);
      await c.setEnabled(true);
      expect(c.materialStyle, SurfaceMaterialStyle.acrylic);
    });
  });
}
