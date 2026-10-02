import 'dart:math' as math;
import 'dart:typed_data';
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

  /// 噪点坐标缓存：固定种子 + 同尺寸 → 坐标恒定，只生成一次。
  ///
  /// 首页功能区有十几块磁贴，且都在同一个滚动层里：任何一次重绘都会让每块
  /// 磁贴的 [paint] 重新跑 `Random` 并分配最多 3000 个 `Offset`（十几块就是
  /// 数万个对象 / 次）。这些都在 UI 线程上，返回首页那几帧尤其不划算。
  static final Map<(double, double), Float32List> _pointCache =
      <(double, double), Float32List>{};
  static const int _pointCacheLimit = 32;

  @visibleForTesting
  static int get debugCachedSizeCount => _pointCache.length;

  @visibleForTesting
  static void debugClearCache() => _pointCache.clear();

  static Float32List? _pointsFor(Size size) {
    final key = (size.width, size.height);
    final cached = _pointCache[key];
    if (cached != null) return cached;
    final count = (size.width * size.height / 32).clamp(0, 3000).toInt();
    if (count == 0) return null;
    final random = math.Random(20240912);
    final points = Float32List(count * 2);
    for (var i = 0; i < count; i++) {
      points[i * 2] = random.nextDouble() * size.width;
      points[i * 2 + 1] = random.nextDouble() * size.height;
    }
    if (_pointCache.length >= _pointCacheLimit) {
      _pointCache.remove(_pointCache.keys.first);
    }
    return _pointCache[key] = points;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0.001 || size.isEmpty) return;
    final points = _pointsFor(size);
    if (points == null) return;

    final baseColor = isDark ? Colors.white : Colors.black;
    final paint = Paint()
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = false
      ..color = baseColor.withValues(alpha: opacity.clamp(0.0, 1.0));
    canvas.drawRawPoints(ui.PointMode.points, points, paint);
  }

  @override
  bool shouldRepaint(MaterialNoisePainter oldDelegate) =>
      oldDelegate.opacity != opacity || oldDelegate.isDark != isDark;
}
