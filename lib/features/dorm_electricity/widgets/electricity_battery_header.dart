import 'package:flutter/material.dart';

class ElectricityBatteryHeader extends StatelessWidget {
  const ElectricityBatteryHeader({
    super.key,
    required this.valueText,
    required this.statusLabel,
    required this.fraction,
    required this.fillAnimationValue,
    required this.breathValue,
    required this.accentColor,
    required this.statusBackgroundColor,
  });

  final String valueText;
  final String statusLabel;
  final double fraction;
  final double fillAnimationValue;
  final double breathValue;
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
    final fillColor = accentColor.withValues(alpha: isDark ? 0.34 : 0.24);
    final animatedFraction = (fraction * fillAnimationValue)
        .clamp(0.0, 1.0)
        .toDouble();
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
                      if (animatedFraction > 0)
                        Positioned.fill(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: animatedFraction,
                              heightFactor: 1,
                              alignment: Alignment.centerLeft,
                              child: ColoredBox(color: fillColor),
                            ),
                          ),
                        ),
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _BatteryPixelPainter(
                            fraction: fraction,
                            fillAnimationValue: fillAnimationValue,
                            breathValue: breathValue,
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
    required this.fillAnimationValue,
    required this.breathValue,
    required this.activeColor,
    required this.emptyColor,
    required this.isDark,
  });

  final double fraction;
  final double fillAnimationValue;
  final double breathValue;
  final Color activeColor;
  final Color emptyColor;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final progress = (fraction * fillAnimationValue).clamp(0.0, 1.0).toDouble();
    final progressX = size.width * progress;
    final breath = ((breathValue - 0.5) * 2).clamp(-1.0, 1.0).toDouble();

    const dotSize = 4.0;
    const gap = 2.8;
    const stride = dotSize + gap;
    final columns = (size.width / stride).ceil() + 2;
    final rows = (size.height / stride).ceil() + 2;
    const startX = -stride;
    final startY = -stride;

    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        final x = startX + column * stride;
        final y = startY + row * stride;
        final centerX = x + dotSize / 2;
        final litAmount = ((progressX - centerX) / 22)
            .clamp(0.0, 1.0)
            .toDouble();
        final edgeBand = ((22 - (progressX - centerX).abs()) / 22)
            .clamp(0.0, 1.0)
            .toDouble();
        final rect = Rect.fromLTWH(x, y, dotSize, dotSize);
        final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(1.1));

        if (litAmount <= 0) {
          final emptyAlpha = ((isDark ? 0.12 : 0.075) + breath * 0.006)
              .clamp(0.0, 0.14)
              .toDouble();
          canvas.drawRRect(
            rrect,
            Paint()..color = emptyColor.withValues(alpha: emptyAlpha),
          );
          continue;
        }

        final alpha =
            ((isDark ? 0.18 : 0.15) + edgeBand * 0.07 + breath * 0.018)
                .clamp(0.0, 0.28)
                .toDouble();
        final color = Color.lerp(
          Colors.white,
          activeColor,
          isDark ? 0.08 : 0.18,
        )!.withValues(alpha: alpha);

        canvas.drawRRect(rrect, Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(_BatteryPixelPainter old) =>
      fraction != old.fraction ||
      fillAnimationValue != old.fillAnimationValue ||
      breathValue != old.breathValue ||
      activeColor != old.activeColor ||
      emptyColor != old.emptyColor ||
      isDark != old.isDark;
}
