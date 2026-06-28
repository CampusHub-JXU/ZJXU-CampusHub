import 'package:flutter/material.dart';

import '../../../app/app_theme_controller.dart';
import '../../../core/theme/app_design_tokens.dart';

/// GPA 摘要卡（PRD FR-6 拆分）。
class GradesGpaSummaryCard extends StatelessWidget {
  const GradesGpaSummaryCard({
    super.key,
    required this.gpa,
    required this.totalCredits,
    required this.courseCount,
  });

  final double gpa;
  final double totalCredits;
  final int courseCount;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = AppThemeController.instance.resolveIconColor(
      context,
      cs.primary,
    );
    final darkAccent = _shiftColor(accent, lightness: -0.08);
    final foreground = _contrastOn(accent);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent.withValues(alpha: 0.92), darkAccent],
        ),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  totalCredits.toStringAsFixed(1),
                  style: TextStyle(
                    fontSize: 44,
                    height: 1,
                    fontWeight: FontWeight.w900,
                    color: foreground,
                    letterSpacing: -1.5,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '已获学分',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: foreground.withValues(alpha: 0.6),
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _SummaryStat(
                  label: 'GPA',
                  value: gpa.toStringAsFixed(2),
                  foreground: foreground,
                ),
                _SummaryStat(
                  label: '课程数',
                  value: '$courseCount',
                  foreground: foreground,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _shiftColor(Color color, {required double lightness}) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness + lightness).clamp(0.1, 0.9))
        .toColor();
  }

  Color _contrastOn(Color background) {
    return background.computeLuminance() > 0.45 ? Colors.black : Colors.white;
  }
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat({
    required this.label,
    required this.value,
    required this.foreground,
  });

  final String label;
  final String value;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: foreground,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: foreground.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }
}
