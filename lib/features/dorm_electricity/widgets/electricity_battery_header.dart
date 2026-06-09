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
        ? Color.lerp(Colors.black, accentColor, 0.1)!
        : Color.lerp(cs.surfaceContainerLowest, accentColor, 0.06)!;
    final wellColor = isDark
        ? Color.lerp(Colors.black, accentColor, 0.07)!
        : Color.lerp(const Color(0xFF06110A), accentColor, 0.08)!;
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
                            emptyColor: isDark
                                ? Color.lerp(Colors.black, accentColor, 0.08)!
                                : Color.lerp(
                                    const Color(0xFF06110A),
                                    accentColor,
                                    0.12,
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
                                  alpha: isDark ? 0.46 : 0.12,
                                ),
                                wellColor.withValues(alpha: 0.02),
                                wellColor.withValues(
                                  alpha: isDark ? 0.34 : 0.2,
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
          const SizedBox(height: 14),
          Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 4),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 58),
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
                          height: 1.12,
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
                          height: 1.12,
                          color: unitColor,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '剩余',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          height: 1.12,
                          color: unitColor.withValues(alpha: 0.78),
                        ),
                      ),
                    ],
                  ),
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
    if (size.isEmpty) return;

    final progress = (fraction * fillAnimation.value)
        .clamp(0.0, 1.0)
        .toDouble();
    final progressX = size.width * progress;
    final breathValue = breathAnimation.value;
    final phase = breathValue * math.pi * 2;
    final pulse = ((math.sin(phase) + 1) / 2).clamp(0.0, 1.0).toDouble();

    _drawFlowBase(canvas, size, progressX);

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
        final fillRamp = progressX <= 0
            ? 0.0
            : (centerX / progressX).clamp(0.0, 1.0).toDouble();
        final wakeGradient = math.pow(fillRamp, 1.55).toDouble();
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
        final wakeLight = _dotCosWakeLight(
          column,
          row,
          breathValue,
          columns: columns,
        );
        final fizzField = _dotFizzField(
          column,
          row,
          breathValue,
          columns: columns,
          rows: rows,
        );
        final alphaNoise =
            (staticGrain * 0.34 +
                    randomField * 0.18 +
                    shimmer * 0.26 +
                    flow * 0.14 +
                    sweep * 0.08 +
                    wakeGradient * 0.36 +
                    wakeLight * 0.46 +
                    fizzField * 0.2)
                .clamp(0.0, 1.0)
                .toDouble();
        final fizzSpark = math.pow(fizzField, 2.6).toDouble();

        if (litAmount <= 0) {
          final emptyAlpha =
              ((isDark ? 0.026 : 0.012) +
                      alphaNoise * 0.026 +
                      fizzSpark * 0.02 +
                      wakeLight * 0.018 +
                      pulse * 0.004)
                  .clamp(0.0, 0.12)
                  .toDouble();
          dotPaint.color = emptyColor.withValues(alpha: emptyAlpha);
          canvas.drawRect(rect, dotPaint);
          continue;
        }

        final fillBreath = 0.76 + pulse * 0.32;
        final sparkBoost =
            math.pow(shimmer, 2.4).toDouble() * 0.1 +
            wakeGradient * 0.2 +
            wakeLight * 0.48 +
            fizzSpark * 0.2;
        final alpha =
            (((isDark ? 0.28 : 0.23) +
                        alphaNoise * 0.5 +
                        edgeBand * 0.12 +
                        sparkBoost) *
                    fillBreath *
                    litAmount)
                .clamp(0.035, 0.96)
                .toDouble();
        final darkDotColor = Color.lerp(
          isDark ? Colors.black : emptyColor,
          activeColor,
          isDark ? 0.18 : 0.26,
        )!;
        final brightDotColor = Color.lerp(
          activeColor,
          isDark ? const Color(0xFF4ED37D) : const Color(0xFF5FD687),
          0.26,
        )!;
        final color = Color.lerp(
          darkDotColor,
          brightDotColor,
          (wakeGradient * 0.5 + wakeLight * 0.56 + alphaNoise * 0.12).clamp(
            0.0,
            1.0,
          ),
        )!.withValues(alpha: alpha);

        dotPaint.color = color;
        canvas.drawRect(rect, dotPaint);
      }
    }
  }

  void _drawFlowBase(Canvas canvas, Size size, double progressX) {
    final rect = Offset.zero & size;
    final basePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Color.lerp(
            emptyColor,
            activeColor,
            isDark ? 0.24 : 0.18,
          )!.withValues(alpha: isDark ? 0.22 : 0.14),
          emptyColor.withValues(alpha: isDark ? 0.11 : 0.07),
          Color.lerp(
            emptyColor,
            activeColor,
            isDark ? 0.02 : 0.06,
          )!.withValues(alpha: isDark ? 0.055 : 0.035),
        ],
        stops: const [0, 0.58, 1],
      ).createShader(rect);
    canvas.drawRect(rect, basePaint);

    if (progressX <= 0) return;

    final activeRect = Rect.fromLTRB(0, 0, progressX, size.height);
    final activePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          activeColor.withValues(alpha: isDark ? 0.46 : 0.38),
          Color.lerp(
            activeColor,
            emptyColor,
            isDark ? 0.34 : 0.42,
          )!.withValues(alpha: isDark ? 0.3 : 0.22),
          Color.lerp(
            emptyColor,
            activeColor,
            isDark ? 0.06 : 0.1,
          )!.withValues(alpha: isDark ? 0.13 : 0.08),
        ],
        stops: const [0, 0.42, 1],
      ).createShader(rect);
    final verticalDepthPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          activeColor.withValues(alpha: isDark ? 0.09 : 0.12),
          Colors.transparent,
          Colors.black.withValues(alpha: isDark ? 0.2 : 0.16),
        ],
        stops: const [0, 0.42, 1],
      ).createShader(activeRect);

    canvas.save();
    canvas.clipRect(activeRect);
    canvas.drawRect(rect, activePaint);
    canvas.drawRect(activeRect, verticalDepthPaint);

    final rightMaskPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Colors.transparent,
          Color.lerp(
            emptyColor,
            Colors.black,
            isDark ? 0.62 : 0.5,
          )!.withValues(alpha: isDark ? 0.36 : 0.28),
          Color.lerp(
            emptyColor,
            Colors.black,
            isDark ? 0.76 : 0.62,
          )!.withValues(alpha: isDark ? 0.74 : 0.48),
          Color.lerp(
            emptyColor,
            Colors.black,
            isDark ? 0.88 : 0.76,
          )!.withValues(alpha: isDark ? 0.98 : 0.72),
        ],
        stops: const [0, 0.42, 0.68, 1],
      ).createShader(activeRect);
    canvas.drawRect(activeRect, rightMaskPaint);
    canvas.restore();
  }

  double _dotCosWakeLight(
    int column,
    int row,
    double breathValue, {
    required int columns,
  }) {
    final x = column / math.max(columns - 1, 1);
    final turbulence =
        math.sin(row * 0.62 + breathValue * math.pi * 2) * 0.016 +
        math.sin((column + row) * 0.17 - breathValue * math.pi * 4) * 0.01;
    final easedLocal = _cyclicEasePhase(breathValue);
    final head = (easedLocal + turbulence) % 1.0;
    final behindHead = (head - x + 1) % 1.0;
    const tailLength = 0.66;
    var strength = 0.0;
    if (behindHead <= tailLength) {
      final tailT = (behindHead / tailLength).clamp(0.0, 1.0).toDouble();
      final tailEnvelope = math.pow((math.cos(tailT * math.pi) + 1) / 2, 1.7);
      final headT = (behindHead / 0.15).clamp(0.0, 1.0).toDouble();
      final headCap = math.pow((math.cos(headT * math.pi) + 1) / 2, 5.0);
      strength = tailEnvelope * 0.58 + headCap * 0.54;
    }
    final turbulentSpark =
        math
            .pow(
              (math.cos(
                        (x * 7.0 + row * 0.31 - breathValue * 2.6) *
                            math.pi *
                            2,
                      ) +
                      1) /
                  2,
              6.0,
            )
            .toDouble() *
        0.16;
    return (strength + turbulentSpark).clamp(0.0, 1.0).toDouble();
  }

  double _dotFizzField(
    int column,
    int row,
    double breathValue, {
    required int columns,
    required int rows,
  }) {
    const clusterCount = 9;
    var strength = 0.0;
    for (var cluster = 0; cluster < clusterCount; cluster++) {
      final phaseOffset = _noise(cluster, 1, 211);
      final speedStep = 1 + (_noise(cluster, 4, 239) * 2).floor();
      final local = (breathValue * speedStep + phaseOffset) % 1.0;
      final travel = _cyclicEasePhase(local);
      final centerColumn = -2.0 + travel * (columns + 4);
      final baseRow = 1.0 + _noise(cluster, 6, 251) * math.max(rows - 2, 1);
      final wobble =
          math.sin(breathValue * math.pi * 2 + cluster * 1.7) *
          (1.2 + _noise(cluster, 8, 271) * 2.6);
      final centerRow = baseRow + wobble;
      final radiusX = 2.2 + _noise(cluster, 10, 281) * 4.2;
      final radiusY = 1.2 + _noise(cluster, 12, 293) * 3.0;
      final dx = (column - centerColumn) / radiusX;
      final dy = (row - centerRow) / radiusY;
      final distance = dx * dx + dy * dy;
      if (distance >= 1) continue;

      final ring = math.sin((1 - distance) * math.pi).abs();
      final grain = _noise(column, row, 307 + cluster);
      strength = math.max(
        strength,
        (ring * 0.78 + grain * 0.22) * (1 - distance * 0.22),
      );
    }
    return strength.clamp(0.0, 1.0).toDouble();
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

  double _cyclicEasePhase(double value) {
    final t = value.clamp(0.0, 1.0).toDouble();
    return (t + math.sin(t * math.pi * 2) * 0.11).clamp(0.0, 1.0).toDouble();
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
