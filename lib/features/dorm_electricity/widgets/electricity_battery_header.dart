import 'dart:math' as math;

import 'package:flutter/material.dart';

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
    final panelColor = isDark
        ? Color.lerp(cs.surfaceContainerLow, accentColor, 0.1)!
        : Color.lerp(cs.surfaceContainerLowest, accentColor, 0.035)!;
    final wellColor = isDark
        ? Color.lerp(cs.surfaceContainerLowest, accentColor, 0.08)!
        : Color.lerp(cs.surfaceContainerHigh, accentColor, 0.07)!;
    final borderColor = Color.lerp(
      isDark ? Colors.white : cs.outlineVariant,
      accentColor,
      isDark ? 0.22 : 0.16,
    )!.withValues(alpha: isDark ? 0.26 : 0.56);
    final valueColor = isDark
        ? Colors.white
        : Color.lerp(cs.onSurface, accentColor, 0.18)!;
    final unitColor = isDark
        ? Colors.white.withValues(alpha: 0.9)
        : Color.lerp(cs.onSurfaceVariant, accentColor, 0.34)!;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '电量详情',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: cs.onSurface,
                  ),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Color.lerp(
                    statusBackgroundColor,
                    cs.surfaceContainerLowest,
                    isDark ? 0.1 : 0.46,
                  ),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: accentColor.withValues(alpha: isDark ? 0.24 : 0.18),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accentColor.withValues(alpha: isDark ? 0.08 : 0.1),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: accentColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 128,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: panelColor,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: borderColor, width: 1.4),
                boxShadow: [
                  BoxShadow(
                    color: accentColor.withValues(alpha: isDark ? 0.06 : 0.05),
                    blurRadius: 18,
                    offset: const Offset(0, 9),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(7),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(17),
                  child: Stack(
                    children: [
                      Positioned.fill(child: ColoredBox(color: wellColor)),
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _BatteryPixelPainter(
                            fraction: fraction,
                            fillAnimation: fillAnimation,
                            breathAnimation: breathAnimation,
                            activeColor: accentColor,
                            emptyColor: Color.lerp(
                              cs.onSurfaceVariant,
                              accentColor,
                              isDark ? 0.08 : 0.16,
                            )!,
                            isDark: isDark,
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [
                                wellColor.withValues(
                                  alpha: isDark ? 0.54 : 0.5,
                                ),
                                wellColor.withValues(alpha: 0.02),
                                wellColor.withValues(
                                  alpha: isDark ? 0.22 : 0.32,
                                ),
                              ],
                              stops: const [0, 0.5, 1],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: FittedBox(
                fit: BoxFit.scaleDown,
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
                        fontSize: 48,
                        fontWeight: FontWeight.w700,
                        height: 1,
                        letterSpacing: 0,
                        color: valueColor,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      '度',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        height: 1,
                        color: unitColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BatteryPixelPainter extends CustomPainter {
  _BatteryPixelPainter({
    required this.fraction,
    required this.fillAnimation,
    required this.breathAnimation,
    required this.activeColor,
    required this.emptyColor,
    required this.isDark,
  }) : super(repaint: Listenable.merge([fillAnimation, breathAnimation]));

  final double fraction;
  final Animation<double> fillAnimation;
  final Animation<double> breathAnimation;
  final Color activeColor;
  final Color emptyColor;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final progress = (fraction * fillAnimation.value)
        .clamp(0.0, 1.0)
        .toDouble();
    final progressX = size.width * progress;
    final breathValue = breathAnimation.value;
    final phase = breathValue * math.pi * 2;
    final pulse = ((math.sin(phase) + 1) / 2).clamp(0.0, 1.0).toDouble();

    const dotSize = 3.2;
    const gap = 1.45;
    const stride = dotSize + gap;
    final columns = (size.width / stride).ceil() + 2;
    final rows = (size.height / stride).ceil() + 2;
    const startX = -stride;
    final startY = -stride;
    final dotPaint = Paint();

    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        final x = startX + column * stride;
        final y = startY + row * stride;
        final centerX = x + dotSize / 2;
        final litAmount = ((progressX - centerX) / 26)
            .clamp(0.0, 1.0)
            .toDouble();
        final edgeBand = ((28 - (progressX - centerX).abs()) / 28)
            .clamp(0.0, 1.0)
            .toDouble();
        final rect = Rect.fromLTWH(x, y, dotSize, dotSize);
        final staticGrain = _noise(column, row, 7);
        final randomField = _smoothNoise(
          column,
          row,
          breathValue,
          frameCount: 8,
          seedBase: 41,
        );
        // Keep every temporal term periodic so repeat() never pops at 1 -> 0.
        final cellPhase = staticGrain * math.pi * 2;
        final shimmer =
            (math.sin(phase * 2 + cellPhase + column * 0.15 - row * 0.05) + 1) /
            2;
        final flow = (math.sin(phase - column * 0.2 + row * 0.11) + 1) / 2;
        final sweep = (math.sin(phase + column * 0.08) + 1) / 2;
        final alphaNoise =
            (staticGrain * 0.34 +
                    randomField * 0.18 +
                    shimmer * 0.26 +
                    flow * 0.14 +
                    sweep * 0.08)
                .clamp(0.0, 1.0)
                .toDouble();

        if (litAmount <= 0) {
          final emptyAlpha =
              ((isDark ? 0.034 : 0.018) + alphaNoise * 0.034 + pulse * 0.006)
                  .clamp(0.0, 0.16)
                  .toDouble();
          dotPaint.color = emptyColor.withValues(alpha: emptyAlpha);
          canvas.drawRect(rect, dotPaint);
          continue;
        }

        final fillBreath = 0.76 + pulse * 0.32;
        final sparkBoost = math.pow(shimmer, 2.4).toDouble() * 0.12;
        final alpha =
            (((isDark ? 0.23 : 0.19) +
                        alphaNoise * 0.44 +
                        edgeBand * 0.1 +
                        sparkBoost) *
                    fillBreath *
                    litAmount)
                .clamp(0.06, 0.84)
                .toDouble();
        final color = Color.lerp(
          Colors.white,
          activeColor,
          (isDark ? 0.22 : 0.36) + alphaNoise * 0.22,
        )!.withValues(alpha: alpha);

        dotPaint.color = color;
        canvas.drawRect(rect, dotPaint);
      }
    }
  }

  double _smoothNoise(
    int column,
    int row,
    double phase, {
    required int frameCount,
    required int seedBase,
  }) {
    final frame = phase * frameCount;
    final currentFrame = frame.floor() % frameCount;
    final nextFrame = (currentFrame + 1) % frameCount;
    final t = frame - frame.floor();
    final easedT = t * t * (3 - 2 * t);
    final current = _noise(column, row, seedBase + currentFrame);
    final next = _noise(column, row, seedBase + nextFrame);
    return current + (next - current) * easedT;
  }

  double _noise(int column, int row, int seed) {
    var hash = column * 374761393 + row * 668265263 + seed * 1442695041;
    hash = (hash ^ (hash >> 13)) * 1274126177;
    hash = hash ^ (hash >> 16);
    return (hash & 0x7fffffff) / 0x7fffffff;
  }

  @override
  bool shouldRepaint(_BatteryPixelPainter old) =>
      fraction != old.fraction ||
      fillAnimation != old.fillAnimation ||
      breathAnimation != old.breathAnimation ||
      activeColor != old.activeColor ||
      emptyColor != old.emptyColor ||
      isDark != old.isDark;
}
