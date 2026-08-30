import 'package:flutter/material.dart';

import '../../../shared/widgets/app_card.dart';
import '../grades_model.dart';
import '../grades_score_palette.dart';

/// 成绩分布卡（PRD FR-6 拆分）。
///
/// 柱状图颜色与成绩卡分数数字共用 [gradeBandColor] 分段 token：
/// 优/良/中/及格为主题色深浅梯度，不及格为 error 语义色。
class GradesDistributionCard extends StatelessWidget {
  const GradesDistributionCard({super.key, required this.grades});

  final List<GradeEntry> grades;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final distribution = _buildDistribution();
    final total = grades.length;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '成绩分布',
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 80,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final (index, entry) in distribution.indexed) ...[
                  Expanded(
                    child: _DistBar(
                      label: entry.label,
                      count: entry.count,
                      total: total,
                      color: gradeBandColor(cs, entry.band),
                    ),
                  ),
                  if (index != distribution.length - 1)
                    const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 分段统计（优→不及格 固定顺序）。
  List<_DistributionEntry> _buildDistribution() {
    final counts = {for (final band in GradeBand.values) band: 0};
    for (final g in grades) {
      final band = gradeBandForScore(double.tryParse(g.percentageScore) ?? 0);
      counts[band] = counts[band]! + 1;
    }
    return [
      for (final band in GradeBand.values)
        _DistributionEntry(label: band.label, band: band, count: counts[band]!),
    ];
  }
}

/// 分段统计条目：展示文案 + 分段 token + 数量。
class _DistributionEntry {
  const _DistributionEntry({
    required this.label,
    required this.band,
    required this.count,
  });

  final String label;
  final GradeBand band;
  final int count;
}

extension _GradeBandLabel on GradeBand {
  String get label => switch (this) {
    GradeBand.excellent => '优',
    GradeBand.good => '良',
    GradeBand.medium => '中',
    GradeBand.pass => '及格',
    GradeBand.fail => '不及格',
  };
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
