import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 程序化噪点纹理（亚克力 / 云母 / 磨砂顶栏共用）。
///
/// 固定随机种子 → 每像素稳定，不引入图片资源；1px 点阵在低不透明度下即为
/// 细微 grain。属于统一材质渲染器的一部分，组件不应各自实现。
class MaterialNoisePainter extends CustomPainter {
  const MaterialNoisePainter({required this.opacity, required this.isDark});

  final double opacity;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final random = math.Random(20240912);
    final count = (size.width * size.height / 24).clamp(0, 4000).toInt();
    final baseColor = isDark ? Colors.white : Colors.black;
    for (var i = 0; i < count; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      final alpha = opacity * (0.35 + random.nextDouble() * 0.65);
      paint.color = baseColor.withValues(alpha: alpha);
      canvas.drawRect(Rect.fromLTWH(x, y, 1, 1), paint);
    }
  }

  @override
  bool shouldRepaint(MaterialNoisePainter oldDelegate) =>
      oldDelegate.opacity != opacity || oldDelegate.isDark != isDark;
}
