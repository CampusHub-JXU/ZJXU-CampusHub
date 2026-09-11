import 'package:flutter/material.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../shared/widgets/app_card.dart';
import '../grades_model.dart';
import '../grades_score_palette.dart';

/// 成绩课程卡（网格单元，PRD FR-6 拆分）。
///
/// 视觉统一：卡片材质走 [AppCard]（发丝线描边，无彩色粗顶条），
/// 分数数字颜色来自 [gradeBandColorForScore] 的主题派生分段色。
class GradesGradeCard extends StatelessWidget {
  const GradesGradeCard({super.key, required this.grade});

  final GradeEntry grade;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final scoreColor = gradeBandColorForScore(
      cs,
      double.tryParse(grade.percentageScore) ?? 0,
    );

    return AppCard(
      radius: AppRadius.cardAlt,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  grade.courseName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                    height: 1.25,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                grade.grade,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  height: 1,
                  color: scoreColor,
                  letterSpacing: -0.8,
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 5,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (grade.credits > 0)
                Text(
                  '${_formatCredits(grade.credits)}学分',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: scoreColor.withValues(alpha: 0.75),
                  ),
                ),
              if (grade.gpaPoints > 0)
                _InfoChip(label: 'GPA ${grade.gpaPoints.toStringAsFixed(1)}'),
              if (grade.assessmentMethod.isNotEmpty)
                _InfoChip(label: grade.assessmentMethod),
              if (grade.assessmentMethod.isEmpty && grade.examType.isNotEmpty)
                _InfoChip(label: grade.examType),
            ],
          ),
        ],
      ),
    );
  }

  String _formatCredits(double value) {
    if (value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(1);
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: cs.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          fontSize: 10,
        ),
      ),
    );
  }
}
