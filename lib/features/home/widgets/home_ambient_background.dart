import 'package:flutter/material.dart';

/// 首页默认环境背景：用户未设置背景图时的最底层。
///
/// 暖灰 / 近黑底色上叠加极淡的酒红径向光晕，为无框第一屏提供
/// 微弱的品牌氛围。纯静态绘制（无动画、无滤镜），并以
/// [RepaintBoundary] 隔离重绘；需在紧约束下使用
/// （如 Stack 首个子节点或 Positioned.fill）。
class HomeAmbientBackground extends StatelessWidget {
  const HomeAmbientBackground({super.key});

  /// 品牌酒红（与 AppColors.primary 一致）。
  static const Color _brandRed = Color(0xFF8B1A2D);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _AmbientPainter(isDark: isDark),
      ),
    );
  }
}

class _AmbientPainter extends CustomPainter {
  const _AmbientPainter({required this.isDark});

  final bool isDark;

  static const Color _lightBase = Color(0xFFF6F4F2);
  static const Color _darkBase = Color(0xFF141213);

  @override
  void paint(Canvas canvas, Size size) {
    // 底色铺满。
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = isDark ? _darkBase : _lightBase,
    );

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
    final glow = HomeAmbientBackground._brandRed.withValues(alpha: alpha);
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..shader = RadialGradient(colors: [glow, glow.withValues(alpha: 0)])
          .createShader(rect);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _AmbientPainter oldDelegate) =>
      oldDelegate.isDark != isDark;
}
