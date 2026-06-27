import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 电量详情卡的核心视觉。
///
/// 排版层级（自上而下）：
/// 1. 眉标 "电量详情" + 状态徽章（右）
/// 2. 大数字 hero（左对齐）+ 单位/标签
/// 3. 细长点阵像素充电条（数字的下划线）
/// 4. 百分比（左）+ 满电刻度（右）
///
/// 配色完全跟随 [accentColor] 与主题 [ColorScheme]。
class ElectricityBatteryHeader extends StatelessWidget {
  const ElectricityBatteryHeader({
    super.key,
    required this.valueText,
    required this.statusLabel,
    required this.fraction,
    required this.fillAnimation,
    required this.breathAnimation,
    required this.accentColor,
    required this.statusBackgroundColor,
  });

  final String valueText;
  final String statusLabel;
  final double fraction;
  final Animation<double> fillAnimation;
  final Animation<double> breathAnimation;
  final Color accentColor;
  final Color statusBackgroundColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final trackColor = isDark
        ? cs.surfaceContainerHighest.withValues(alpha: 0.55)
        : cs.surfaceContainerHighest;
    final valueColor = cs.onSurface;
    final unitColor = cs.onSurfaceVariant;
    final dimColor = cs.onSurfaceVariant.withValues(alpha: 0.9);
    final pillBg = Color.lerp(
      statusBackgroundColor,
      cs.surfaceContainerLowest,
      isDark ? 0.12 : 0.5,
    )!;
    final pillBorder = accentColor.withValues(alpha: isDark ? 0.3 : 0.24);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 眉标 + 状态徽章 ──
        Row(
          children: [
            Text(
              '电量详情',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: dimColor,
                letterSpacing: 1.2,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: pillBg,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: pillBorder, width: 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: accentColor,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: accentColor.withValues(alpha: 0.4),
                          blurRadius: 5,
                          spreadRadius: 0.3,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    statusLabel,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: accentColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // ── 大数字 hero（左对齐）──
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            mainAxisSize: MainAxisSize.min,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                valueText,
                style: TextStyle(
                  fontFamily: 'DIN Alternate',
                  fontFamilyFallback: const ['Roboto', 'Arial'],
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontSize: 60,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                  letterSpacing: -1.5,
                  color: valueColor,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                '度',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                  color: unitColor,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '剩余',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                  letterSpacing: 0.4,
                  color: dimColor,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        // ── 点阵像素充电条（数字的下划线）──
        SizedBox(
          height: 18,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ColoredBox(
                        color: trackColor,
                        child: const SizedBox.shrink(),
                      ),
                    ),
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _PixelMatrixBarPainter(
                          fraction: fraction,
                          fillAnimation: fillAnimation,
                          breathAnimation: breathAnimation,
                          activeColor: accentColor,
                          trackColor: trackColor,
                          isDark: isDark,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 7),
        // ── 百分比（左）+ 满电刻度（右）──
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              '${(fraction * 100).round()}%',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: accentColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const Spacer(),
            Text('满电 100 度', style: TextStyle(fontSize: 11, color: dimColor)),
          ],
        ),
      ],
    );
  }
}

/// 细长点阵像素充电条绘制。
///
/// 在 18px 高的胶囊轨道上排列 ~3.4px 像素方点：
/// - 已充段（progressX 左侧）点阵根据 wake light / shimmer / flow / fizz
///   动效网点亮度，颜色跟随 [activeColor]，无硬编码亮绿。
/// - 未充段点阵以极低 alpha 静态噪点呈现像素纹理，不喧宾夺主。
/// - 保留进场 fill 动画（左侧逐渐点亮）与 4.7s 呼吸节律。
class _PixelMatrixBarPainter extends CustomPainter {
  _PixelMatrixBarPainter({
    required this.fraction,
    required this.fillAnimation,
    required this.breathAnimation,
    required this.activeColor,
    required this.trackColor,
    required this.isDark,
  }) : super(repaint: Listenable.merge([fillAnimation, breathAnimation]));

  final double fraction;
  final Animation<double> fillAnimation;
  final Animation<double> breathAnimation;
  final Color activeColor;
  final Color trackColor;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final progress = (fraction * fillAnimation.value)
        .clamp(0.0, 1.0)
        .toDouble();
    final progressX = size.width * progress;
    final breath = breathAnimation.value;
    final phase = breath * math.pi * 2;
    final pulse = ((math.sin(phase) + 1) / 2).clamp(0.0, 1.0).toDouble();

    // 点阵网格：自适应尺寸，保证至少 2 行。
    const dotSize = 3.0;
    const gap = 1.6;
    const stride = dotSize + gap;
    final columns = (size.width / stride).ceil() + 1;
    final rows = (size.height / stride).ceil();
    final startX = (size.width - (columns - 1) * stride - dotSize) / 2;
    final startY = (size.height - (rows - 1) * stride - dotSize) / 2;
    final dotPaint = Paint();

    // 水平衰减 envelope：[0, 0.5] 保持亮度，[0.5, 0.75] 线性衰减到 0，之后为 0。
    double attenuate(double normalizedX) {
      if (normalizedX <= 0.5) return 1.0;
      if (normalizedX >= 0.75) return 0.0;
      return 1.0 - (normalizedX - 0.5) / 0.25;
    }

    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < columns; col++) {
        final x = startX + col * stride;
        final y = startY + row * stride;
        final centerX = x + dotSize / 2;
        final rect = Rect.fromLTWH(x, y, dotSize, dotSize);

        // 已充段内每点的视觉权重
        if (progressX <= 0 || centerX > progressX) {
          // 未充段：极低 alpha 像素纹理
          final grain = _noise(col, row, 7);
          final emptyAlpha =
              ((isDark ? 0.022 : 0.014) + grain * 0.02 + pulse * 0.004)
                  .clamp(0.0, 0.08)
                  .toDouble();
          dotPaint.color = trackColor.withValues(alpha: emptyAlpha);
          canvas.drawRect(rect, dotPaint);
          continue;
        }

        // 已充段：综合 wake light / shimmer / flow / fizz 动效
        final litAmount = ((progressX - centerX) / 22)
            .clamp(0.0, 1.0)
            .toDouble();
        final wakeGradient = math
            .pow((centerX / progressX).clamp(0.0, 1.0).toDouble(), 1.55)
            .toDouble();
        final staticGrain = _noise(col, row, 7);
        final shimmer =
            (math.sin(phase * 2 + staticGrain * math.pi * 2 + col * 0.15) + 1) /
            2;
        final flow = (math.sin(phase - col * 0.2 + row * 0.5) + 1) / 2;
        final wakeLight = _wakeLight(
          col,
          row,
          breath,
          columns: columns,
          rows: rows,
        );
        final fizz = _fizz(col, row, breath, columns: columns, rows: rows);

        final alphaNoise =
            ((staticGrain * 0.28 +
                    shimmer * 0.24 +
                    flow * 0.12 +
                    wakeGradient * 0.3 +
                    wakeLight * 0.5 +
                    fizz * 0.18))
                .clamp(0.0, 1.0)
                .toDouble();
        final fillBreath = 0.74 + pulse * 0.32;
        final sparkBoost =
            math.pow(shimmer, 2.4).toDouble() * 0.08 +
            wakeGradient * 0.16 +
            wakeLight * 0.5 +
            math.pow(fizz, 2.4).toDouble() * 0.18;

        final alpha =
            (((isDark ? 0.24 : 0.2) + alphaNoise * 0.5 + sparkBoost) *
                    fillBreath *
                    litAmount *
                    attenuate(centerX / size.width))
                .clamp(0.0, 0.95)
                .toDouble();

        // 颜色仅在 activeColor 与其暗化/亮化变体间插值，不再硬编码亮绿。
        final dimDot = Color.lerp(
          activeColor,
          Colors.black,
          isDark ? 0.18 : 0.28,
        )!;
        final brightDot = Color.lerp(activeColor, Colors.white, 0.22)!;
        final dotColor = Color.lerp(
          dimDot,
          brightDot,
          (wakeGradient * 0.4 + wakeLight * 0.6 + alphaNoise * 0.1)
              .clamp(0.0, 1.0)
              .toDouble(),
        )!.withValues(alpha: alpha);

        dotPaint.color = dotColor;
        canvas.drawRect(rect, dotPaint);
      }
    }

    // 右边缘亮线（已充段末尾），随水平衰减 envelope 同步淡化。
    if (progressX > 0 && progressX < size.width) {
      final edgeAtt = attenuate(progressX / size.width);
      if (edgeAtt > 0) {
        canvas.drawRect(
          Rect.fromLTRB(progressX - 1.2, 0, progressX, size.height),
          Paint()
            ..color = activeColor.withValues(
              alpha: (isDark ? 0.32 : 0.42) * edgeAtt,
            ),
        );
      }
    }
  }

  /// 移动光头尾迹：从左到右扫描，在尾迹弧内点亮像素。
  double _wakeLight(
    int col,
    int row,
    double breath, {
    required int columns,
    required int rows,
  }) {
    final x = col / math.max(columns - 1, 1);
    final turbulence =
        math.sin(row * 0.62 + breath * math.pi * 2) * 0.016 +
        math.sin((col + row) * 0.17 - breath * math.pi * 4) * 0.01;
    final eased = (breath).clamp(0.0, 1.0);
    final head = (eased + turbulence) % 1.0;
    final behind = (head - x + 1) % 1.0;
    const tailLength = 0.66;
    var strength = 0.0;
    if (behind <= tailLength) {
      final tailT = (behind / tailLength).clamp(0.0, 1.0).toDouble();
      final tailEnvelope = math
          .pow((math.cos(tailT * math.pi) + 1) / 2, 1.7)
          .toDouble();
      final headT = (behind / 0.15).clamp(0.0, 1.0).toDouble();
      final headCap = math
          .pow((math.cos(headT * math.pi) + 1) / 2, 5.0)
          .toDouble();
      strength = tailEnvelope * 0.58 + headCap * 0.54;
    }
    final turbulentSpark =
        math
            .pow(
              (math.cos((x * 7.0 + row * 0.31 - breath * 2.6) * math.pi * 2) +
                      1) /
                  2,
              6.0,
            )
            .toDouble() *
        0.14;
    return (strength + turbulentSpark).clamp(0.0, 1.0).toDouble();
  }

  /// Fizz 闪烁场：少量随机移动的发光簇，制造像素点间歇性闪烁。
  double _fizz(
    int col,
    int row,
    double breath, {
    required int columns,
    required int rows,
  }) {
    const clusterCount = 6;
    var strength = 0.0;
    for (var cluster = 0; cluster < clusterCount; cluster++) {
      final phaseOffset = _noise(cluster, 1, 211);
      final speedStep = 1 + (_noise(cluster, 4, 239) * 2).floor();
      final local = (breath * speedStep + phaseOffset) % 1.0;
      final centerCol = -2.0 + local * (columns + 4);
      final baseRow = 1.0 + _noise(cluster, 6, 251) * math.max(rows - 2, 1);
      final wobble =
          math.sin(breath * math.pi * 2 + cluster * 1.7) *
          (0.8 + _noise(cluster, 8, 271) * 1.6);
      final centerRow = baseRow + wobble;
      final radiusX = 2.0 + _noise(cluster, 10, 281) * 3.6;
      final radiusY = 1.0 + _noise(cluster, 12, 293) * 2.4;
      final dx = (col - centerCol) / radiusX;
      final dy = (row - centerRow) / radiusY;
      final distance = dx * dx + dy * dy;
      if (distance >= 1) continue;
      final ring = math.sin((1 - distance) * math.pi).abs();
      final grain = _noise(col, row, 307 + cluster);
      strength = math.max(
        strength,
        (ring * 0.72 + grain * 0.22) * (1 - distance * 0.22),
      );
    }
    return strength.clamp(0.0, 1.0).toDouble();
  }

  double _noise(int col, int row, int seed) {
    var hash = col * 374761393 + row * 668265263 + seed * 1442695041;
    hash = (hash ^ (hash >> 13)) * 1274126177;
    hash = hash ^ (hash >> 16);
    return (hash & 0x7fffffff) / 0x7fffffff;
  }

  @override
  bool shouldRepaint(_PixelMatrixBarPainter old) =>
      fraction != old.fraction ||
      fillAnimation != old.fillAnimation ||
      breathAnimation != old.breathAnimation ||
      activeColor != old.activeColor ||
      trackColor != old.trackColor ||
      isDark != old.isDark;
}
