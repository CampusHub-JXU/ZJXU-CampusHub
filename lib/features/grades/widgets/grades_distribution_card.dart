import 'package:flutter/material.dart';

import '../grades_model.dart';

/// 成绩分布卡（PRD FR-6 拆分）。
class GradesDistributionCard extends StatelessWidget {
  const GradesDistributionCard({super.key, required this.grades});

  final List<GradeEntry> grades;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final distribution = _buildDistribution();
    final total = grades.length;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.4),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '成绩分布',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 80,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final entry in distribution.entries) ...[
                  Expanded(
                    child: _DistBar(
                      label: entry.key,
                      count: entry.value,
                      total: total,
                      color: _barColor(entry.key),
                    ),
                  ),
                  if (entry.key != distribution.keys.last)
                    const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Map<String, int> _buildDistribution() {
    int excellent = 0, good = 0, medium = 0, pass = 0, fail = 0;
    for (final g in grades) {
      final score = double.tryParse(g.percentageScore) ?? 0;
      if (score >= 90) {
        excellent++;
      } else if (score >= 80) {
        good++;
      } else if (score >= 70) {
        medium++;
      } else if (score >= 60) {
        pass++;
      } else {
        fail++;
      }
    }
    return {'优': excellent, '良': good, '中': medium, '及格': pass, '不及格': fail};
  }

  Color _barColor(String label) {
    switch (label) {
      case '优':
        return const Color(0xFF16A34A);
      case '良':
        return const Color(0xFF2563EB);
      case '中':
        return const Color(0xFFF59E0B);
      case '及格':
        return const Color(0xFFF97316);
      case '不及格':
        return const Color(0xFFDC2626);
      default:
        return const Color(0xFF9CA3AF);
    }
  }
}

class _DistBar extends StatelessWidget {
  const _DistBar({
    required this.label,
    required this.count,
    required this.total,
    required this.color,
  });

  final String label;
  final int count;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final fraction = total > 0 ? count / total : 0.0;
    final barHeight = fraction > 0 ? fraction.clamp(0.06, 1.0) : 0.0;
    final cs = Theme.of(context).colorScheme;

    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          count > 0 ? '$count' : '',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: color.withValues(alpha: 0.85),
            height: 1,
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: barHeight,
              widthFactor: 1,
              child: Container(
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}