import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 程序化细微噪点纹理（亚克力材质专用）。
///
/// 固定随机种子 → 每像素稳定，不引入图片资源；单像素点阵在低不透明度下表现为
/// 极细微真实 grain（微粒）。属于统一材质渲染器的一部分，组件不应各自实现。
class MaterialNoisePainter extends CustomPainter {
  const MaterialNoisePainter({required this.opacity, required this.isDark});

  final double opacity;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0.001 || size.isEmpty) return;
    final random = math.Random(20240912);
    final count = (size.width * size.height / 32).clamp(0, 3000).toInt();
    if (count == 0) return;

    final points = <Offset>[];
    for (var i = 0; i < count; i++) {
      points.add(
        Offset(
          random.nextDouble() * size.width,
          random.nextDouble() * size.height,
        ),
      );
    }

    final baseColor = isDark ? Colors.white : Colors.black;
    final paint = Paint()
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = false
      ..color = baseColor.withValues(alpha: opacity.clamp(0.0, 1.0));
    canvas.drawPoints(ui.PointMode.points, points, paint);
  }

  @override
  bool shouldRepaint(MaterialNoisePainter oldDelegate) =>
      oldDelegate.opacity != opacity || oldDelegate.isDark != isDark;
}
