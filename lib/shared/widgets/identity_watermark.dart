import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_typography.dart';

/// 全屏、极淡、斜向重复的身份水印（防截图外传）。
///
/// 纯静态：无动画、无 Ticker、不随滚动重绘（[RepaintBoundary] 隔离）。每个
/// 平铺单元把 [lines] 逐行居中叠放，整体旋转约 -30°，奇数行错半个间距，
/// 看上去是斜纹文字而非点阵。[lines] 为空时不绘制任何东西。
///
/// 调用方负责把它放在内容之上并包 `IgnorePointer`（水印不拦截触摸）。
/// 标识只用于绘制，**不得写日志**。
class IdentityWatermark extends StatefulWidget {
  const IdentityWatermark({super.key, required this.lines});

  /// 每个平铺单元内自上而下的文字行；调用方已去重、去空。
  final List<String> lines;

  /// 水印整体旋转角（弧度，逆时针为负）。
  static const double angle = -30 * math.pi / 180;

  /// 平铺单元的水平 / 垂直间距。
  static const double pitchX = 200;
  static const double pitchY = 120;

  /// 单元内两行文字的行间距。
  static const double lineGap = 4;

  /// 浅色 / 深色下的文字不透明度（每种亮度只有一个值）。
  static const double lightAlpha = 0.06;
  static const double darkAlpha = 0.08;

  @override
  State<IdentityWatermark> createState() => _IdentityWatermarkState();
}

class _IdentityWatermarkState extends State<IdentityWatermark> {
  _WatermarkPainter? _painter;

  _WatermarkPainter _resolvePainter(BuildContext context) {
    final theme = Theme.of(context);
    final alpha = theme.brightness == Brightness.dark
        ? IdentityWatermark.darkAlpha
        : IdentityWatermark.lightAlpha;
    final color = theme.colorScheme.onSurface.withValues(alpha: alpha);
    final style = context.appText.meta.copyWith(
      color: color,
      letterSpacing: 0.5,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final current = _painter;
    if (current != null &&
        current.style == style &&
        listEquals(current.lines, widget.lines)) {
      return current;
    }
    current?.disposeText();
    return _painter = _WatermarkPainter(
      lines: List<String>.unmodifiable(widget.lines),
      style: style,
    );
  }

  @override
  void dispose() {
    _painter?.disposeText();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lines.isEmpty) return const SizedBox.shrink();
    return RepaintBoundary(
      child: CustomPaint(
        painter: _resolvePainter(context),
        size: Size.infinite,
      ),
    );
  }
}

class _WatermarkPainter extends CustomPainter {
  _WatermarkPainter({required this.lines, required this.style}) {
    // 文字不随系统字号缩放：水印是装饰层，缩放只会让它变大变显眼。
    _painters = [
      for (final line in lines)
        TextPainter(
          text: TextSpan(text: line, style: style),
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
          maxLines: 1,
        )..layout(),
    ];
  }

  final List<String> lines;
  final TextStyle style;
  late final List<TextPainter> _painters;

  @override
  void paint(Canvas canvas, Size size) {
    if (_painters.isEmpty || size.isEmpty) return;
    const pitchX = IdentityWatermark.pitchX;
    const pitchY = IdentityWatermark.pitchY;
    const gap = IdentityWatermark.lineGap;

    final blockHeight =
        _painters.fold<double>(0, (sum, p) => sum + p.height) +
        gap * (_painters.length - 1);

    // 旋转后要铺满原矩形：在旋转坐标系里覆盖原矩形的外接盒。
    final cosA = math.cos(IdentityWatermark.angle).abs();
    final sinA = math.sin(IdentityWatermark.angle).abs();
    final halfW = (size.width * cosA + size.height * sinA) / 2 + pitchX;
    final halfH = (size.width * sinA + size.height * cosA) / 2 + pitchY;

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(IdentityWatermark.angle);

    var row = 0;
    for (var y = -halfH; y <= halfH; y += pitchY, row++) {
      final shift = row.isOdd ? pitchX / 2 : 0.0;
      for (var x = -halfW + shift; x <= halfW; x += pitchX) {
        var dy = y - blockHeight / 2;
        for (final painter in _painters) {
          painter.paint(canvas, Offset(x - painter.width / 2, dy));
          dy += painter.height + gap;
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WatermarkPainter old) =>
      old.style != style || !listEquals(old.lines, lines);

  /// 释放文字排版缓存；painter 被替换或 State 销毁时调用。
  void disposeText() {
    for (final p in _painters) {
      p.dispose();
    }
  }
}
