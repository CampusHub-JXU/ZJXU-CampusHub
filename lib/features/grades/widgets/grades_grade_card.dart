import 'package:flutter/material.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../grades_model.dart';

/// 成绩课程卡（网格单元，PRD FR-6 拆分）。
class GradesGradeCard extends StatelessWidget {
  const GradesGradeCard({super.key, required this.grade});

  final GradeEntry grade;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final scoreColor = _scoreColor();

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.cardAlt),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.4),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 3,
            decoration: BoxDecoration(
              color: scoreColor.withValues(alpha: 0.75),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  grade.courseName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      grade.grade,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        height: 1,
                        color: scoreColor,
                        letterSpacing: -0.8,
                      ),
                    ),
                    if (grade.credits > 0) ...[
                      const SizedBox(width: 6),
                      Text(
                        '${_formatCredits(grade.credits)}学分',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scoreColor.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 5,
                  runSpacing: 4,
                  children: [
                    if (grade.gpaPoints > 0)
                      _InfoChip(
                        label: 'GPA ${grade.gpaPoints.toStringAsFixed(1)}',
                      ),
                    if (grade.assessmentMethod.isNotEmpty)
                      _InfoChip(label: grade.assessmentMethod),
                    if (grade.assessmentMethod.isEmpty &&
                        grade.examType.isNotEmpty)
                      _InfoChip(label: grade.examType),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _scoreColor() {
    final score = double.tryParse(grade.percentageScore) ?? 0;
    if (score >= 90) return const Color(0xFF16A34A);
    if (score >= 80) return const Color(0xFF2563EB);
    if (score >= 70) return const Color(0xFFF59E0B);
    if (score >= 60) return const Color(0xFFF97316);
    return const Color(0xFFDC2626);
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