import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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
