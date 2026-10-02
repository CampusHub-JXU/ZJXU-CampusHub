import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/shared/widgets/material_noise.dart';

void main() {
  setUp(MaterialNoisePainter.debugClearCache);

  test('noise points are generated once per size and reused', () {
    const painter = MaterialNoisePainter(opacity: 0.04, isDark: false);
    for (var i = 0; i < 3; i++) {
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(160, 80));
      recorder.endRecording().dispose();
    }
    expect(MaterialNoisePainter.debugCachedSizeCount, 1);

    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), const Size(200, 100));
    recorder.endRecording().dispose();
    expect(MaterialNoisePainter.debugCachedSizeCount, 2);
  });

  test('transparent or empty paints do not populate the cache', () {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const MaterialNoisePainter(
      opacity: 0,
      isDark: true,
    ).paint(canvas, const Size(160, 80));
    const MaterialNoisePainter(
      opacity: 0.04,
      isDark: true,
    ).paint(canvas, Size.zero);
    recorder.endRecording().dispose();
    expect(MaterialNoisePainter.debugCachedSizeCount, 0);
  });
}
