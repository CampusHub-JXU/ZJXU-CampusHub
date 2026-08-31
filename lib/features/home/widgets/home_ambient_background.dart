import 'package:flutter/material.dart';

/// 首页默认环境背景：用户未设置背景图时的最底层。
///
/// 底色取主题 scaffold 背景色（与「我的」等其他页面无色差），其上
/// 叠加极淡的主题主色径向光晕，为无框第一屏提供微弱的品牌氛围；
/// 颜色跟随设置中的主题配色（种子色）。纯静态绘制（无动画、
/// 无滤镜），并以 [RepaintBoundary] 隔离重绘；需在紧约束下使用
/// （如 Stack 首个子节点或 Positioned.fill）。
class HomeAmbientBackground extends StatelessWidget {
  const HomeAmbientBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _AmbientPainter(
          isDark: theme.brightness == Brightness.dark,
          base: theme.scaffoldBackgroundColor,
          glow: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _AmbientPainter extends CustomPainter {
  const _AmbientPainter({
    required this.isDark,
    required this.base,
    required this.glow,
  });

  final bool isDark;

  /// 底色：与 Scaffold 背景一致，避免与其他页面出现色差。
  final Color base;

  /// 光晕色：主题主色，跟随设置中的种子色。
  final Color glow;

  @override
  void paint(Canvas canvas, Size size) {
    // 底色铺满。
    canvas.drawRect(Offset.zero & size, Paint()..color = base);

    // 顶部偏右上的主光晕；深色模式下加强以在近黑底上保持可感知。
    _paintGlow(
      canvas,
      size,
      center: Offset(size.width * 0.78, -size.height * 0.12),
      radius: size.width * 0.9,
      alpha: isDark ? 0.08 : 0.05,
    );
    // 底部偏左的次级光晕，压住页面底部。
    _paintGlow(
      canvas,
      size,
      center: Offset(size.width * 0.15, size.height * 1.05),
      radius: size.width * 0.7,
      alpha: isDark ? 0.03 : 0.02,
    );
  }

  void _paintGlow(
    Canvas canvas,
    Size size, {
    required Offset center,
    required double radius,
    required double alpha,
  }) {
    final glowColor = glow.withValues(alpha: alpha);
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [glowColor, glowColor.withValues(alpha: 0)],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _AmbientPainter oldDelegate) =>
      oldDelegate.isDark != isDark ||
      oldDelegate.base != base ||
      oldDelegate.glow != glow;
}
