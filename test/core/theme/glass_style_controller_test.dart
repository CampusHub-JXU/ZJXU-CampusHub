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

  group('磨砂闪粉开关', () {
    test('默认关闭', () {
      expect(GlassStyleController.instance.frostGrainEnabled.value, isFalse);
    });

    test('开启后持久化，重启恢复后仍为开启，且不影响亚克力开关', () async {
      final c = GlassStyleController.instance;
      await c.setFrostGrainEnabled(true);
      expect(c.frostGrainEnabled.value, isTrue);
      expect(c.enabled.value, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('frost_grain_enabled_v1'), isTrue);

      // 模拟冷启动：内存回到默认，再从磁盘恢复。
      c.frostGrainEnabled.value = false;
      c.debugMarkUnrestored();
      await c.restore();
      expect(c.frostGrainEnabled.value, isTrue);
      expect(c.enabled.value, isTrue);
    });

    test('从未设置过时恢复为默认关闭', () async {
      final c = GlassStyleController.instance;
      c.frostGrainEnabled.value = true;
      c.debugMarkUnrestored();
      await c.restore();
      expect(c.frostGrainEnabled.value, isFalse);
    });

    test('值未变化不通知也不写盘', () async {
      final c = GlassStyleController.instance;
      var notified = 0;
      void listener() => notified++;
      c.surfaceChanged.addListener(listener);
      addTearDown(() => c.surfaceChanged.removeListener(listener));

      await c.setFrostGrainEnabled(false);
      expect(notified, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('frost_grain_enabled_v1'), isFalse);

      await c.setFrostGrainEnabled(true);
      expect(notified, 1);
    });
  });
}
