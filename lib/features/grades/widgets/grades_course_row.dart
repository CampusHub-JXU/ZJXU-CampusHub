import 'package:flutter/material.dart';

import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_list_tile.dart';
import '../grades_model.dart';
import '../grades_score_palette.dart';

/// 成绩列表单列行：左课程名 + 元信息，右成绩。
///
/// 元信息「4 学分 · 考试 · 绩点 4.5」；[termLabel] 非空时（「全部」视图）
/// 追加学期短标签。成绩色：优 `primary`、不及格 `error`、其余 `onSurface`。
class GradesCourseRow extends StatelessWidget {
  const GradesCourseRow({super.key, required this.grade, this.termLabel});

  final GradeEntry grade;
  final String? termLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final method = grade.assessmentMethod.isNotEmpty
        ? grade.assessmentMethod
        : grade.examType;
    final meta = [
      if (grade.credits > 0) '${_formatNumber(grade.credits)} 学分',
      if (method.isNotEmpty) method,
      if (grade.gpaPoints > 0) '绩点 ${_formatNumber(grade.gpaPoints)}',
      if (termLabel != null && termLabel!.isNotEmpty) termLabel!,
    ].join(' · ');

    return AppListTile(
      title: grade.courseName,
      meta: meta,
      trailing: Text(
        grade.grade,
        style: context.appText.rowValue.copyWith(
          color: gradeScoreColor(cs, gradeBandForEntry(grade)),
        ),
      ),
    );
  }

  static String _formatNumber(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
}
