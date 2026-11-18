import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/theme/personalization_controller.dart';

void main() {
  final controller = PersonalizationController.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller.debugReset();
  });

  test('home defaults enable watermark and courses but hide notices', () async {
    await controller.init();

    expect(controller.emblemWatermarkEnabled.value, isTrue);
    expect(controller.fullDayCoursesEnabled.value, isTrue);
    expect(controller.homeCampusNoticeEnabled.value, isFalse);
  });

  test('init restores disabled home presentation preferences', () async {
    SharedPreferences.setMockInitialValues({
      'home_emblem_watermark_enabled': false,
      'home_full_day_courses_enabled': false,
      'home_campus_notice_enabled': false,
    });

    await controller.init();

    expect(controller.emblemWatermarkEnabled.value, isFalse);
    expect(controller.fullDayCoursesEnabled.value, isFalse);
    expect(controller.homeCampusNoticeEnabled.value, isFalse);
  });

  test('home presentation preference setters persist values', () async {
    await controller.setEmblemWatermarkEnabled(false);
    await controller.setFullDayCoursesEnabled(false);
    await controller.setHomeCampusNoticeEnabled(false);

    controller.debugReset();
    await controller.init();

    expect(controller.emblemWatermarkEnabled.value, isFalse);
    expect(controller.fullDayCoursesEnabled.value, isFalse);
    expect(controller.homeCampusNoticeEnabled.value, isFalse);
  });

  group('流体 Shader 默认值', () {
    test('出厂默认为开，全新安装（无键、无壁纸）读到开', () async {
      expect(PersonalizationController.kShaderEnabledDefault, isTrue);
      controller.shaderEnabled.value = false;

      await controller.init();

      expect(controller.shaderEnabled.value, isTrue);
    });

    test('用户显式关闭过（存了 false）不被默认值覆盖', () async {
      SharedPreferences.setMockInitialValues({'home_shader_enabled': false});

      await controller.init();

      expect(controller.shaderEnabled.value, isFalse);
    });

    test('用户显式开启过保持开启', () async {
      SharedPreferences.setMockInitialValues({'home_shader_enabled': true});
      controller.shaderEnabled.value = false;

      await controller.init();

      expect(controller.shaderEnabled.value, isTrue);
    });

    test('旧版显式 false（home_color_filter_enabled）同样优先', () async {
      SharedPreferences.setMockInitialValues({
        'home_color_filter_enabled': false,
      });

      await controller.init();

      expect(controller.shaderEnabled.value, isFalse);
    });

    test('升级用户：已存壁纸路径且从未选过 Shader → 保持关并落盘为显式 false', () async {
      SharedPreferences.setMockInitialValues({
        'home_background_image_path': '/nonexistent/old_wallpaper.png',
      });

      await controller.init();

      expect(controller.shaderEnabled.value, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('home_shader_enabled'), isFalse);

      // 之后（壁纸文件已不在、路径键被清掉）重启也不会被默认值翻转。
      controller.debugReset();
      await controller.init();
      expect(controller.shaderEnabled.value, isFalse);
    });

    test('帧率默认 60，档位为 30/45/60/90/120', () async {
      expect(PersonalizationController.kShaderFpsDefault, 60);
      expect(PersonalizationController.kShaderFpsSteps, [30, 45, 60, 90, 120]);

      await controller.init();

      expect(controller.shaderFps.value, 60);
    });

    test('帧率持久化后重启读回，非档位值吸附到最近档', () async {
      await controller.setShaderFps(30);
      controller.debugReset();
      await controller.init();
      expect(controller.shaderFps.value, 30);

      await controller.setShaderFps(100);
      expect(controller.shaderFps.value, 90);
      await controller.setShaderFps(1000);
      expect(controller.shaderFps.value, 120);
      await controller.setShaderFps(1);
      expect(controller.shaderFps.value, 30);
    });

    test('被手改成非法帧率的持久化值读回时吸附', () async {
      SharedPreferences.setMockInitialValues({'home_shader_fps': 77});

      await controller.init();

      expect(controller.shaderFps.value, 90);
    });

    test('setShaderEnabled 写入后重启读回', () async {
      await controller.setShaderEnabled(false);
      controller.debugReset();
      await controller.init();
      expect(controller.shaderEnabled.value, isFalse);
    });
  });

  testWidgets('monet colors come from the background image, not defaults', (
    tester,
  ) async {
    late File file;
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 64, 64),
        Paint()..color = const Color(0xFFE91E63),
      );
      canvas.drawRect(
        const Rect.fromLTWH(64, 0, 64, 64),
        Paint()..color = const Color(0xFF1E88E5),
      );
      final image = await recorder.endRecording().toImage(128, 64);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      image.dispose();
      final dir = await Directory.systemTemp.createTemp('monet_test');
      file = File('${dir.path}/bg.png');
      await file.writeAsBytes(bytes.buffer.asUint8List());
    });
    addTearDown(() => file.parent.deleteSync(recursive: true));

    controller.backgroundImagePath.value = file.path;
    final colors = (await tester.runAsync(controller.getMonetColors))!;

    expect(colors, hasLength(5));
    expect(colors.first, isNot(const Color(0xFF8B1A2D)));
    final pinkish = HSLColor.fromColor(colors.first);
    expect(pinkish.saturation, greaterThan(0.5));
  });
}
