import 'package:flutter/material.dart';

import '../../../app/app_theme_controller.dart';
import '../models/home_presentation.dart';

/// Today Section：当天剩余课程 + 今日考试的紧凑纯文字列表。
///
/// 「今天」标题 + 约 44 行高的单行条目（时间 / 课程名 / 地点），
/// 行间发丝分隔线，无卡片容器；无内容时整块不渲染。
class HomeTodaySection extends StatelessWidget {
  const HomeTodaySection({super.key, required this.today});

  final HomeTodayPresentation today;

  /// 时间列最小宽度，分隔线左缩进与其对齐。
  static const double _timeColumnWidth = 46;
  static const double _rowGap = 12;

  @override
  Widget build(BuildContext context) {
    if (today.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final primaryTextColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      cs.onSurface,
    );
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(context, cs.onSurfaceVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '今天',
          style: Theme.of(context).textTheme.titleSmall!.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: primaryTextColor,
          ),
        ),
        // 考试行在前、课程行在后（模型即分开存储，保持顺序简单）。
        for (final exam in today.exams)
          _buildExamRow(
            context,
            exam,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
          ),
        for (final (index, course) in today.courses.indexed) ...[
          if (index > 0 || today.exams.isNotEmpty) _buildDivider(context),
          _buildCourseRow(
            context,
            course,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
          ),
        ],
      ],
    );
  }

  /// 行间发丝分隔线，左缩进对齐文本起始列。
  Widget _buildDivider(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 1,
      margin: const EdgeInsets.only(left: _timeColumnWidth + _rowGap),
      color: cs.outlineVariant.withValues(alpha: 0.35),
    );
  }

  /// 课程行：时间 + 课程名（进行中加圆点与胶囊）+ 右对齐地点。
  Widget _buildCourseRow(
    BuildContext context,
    HomeTodayCourseRow course, {
    required Color primaryTextColor,
    required Color secondaryTextColor,
  }) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      // 竖向 padding 撑起约 44 行高，随 textScaler 自然缩放。
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: _timeColumnWidth),
            child: Text(
              course.timeText,
              style: textTheme.labelSmall!.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: secondaryTextColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: _rowGap),
          Expanded(
            flex: 3,
            child: Row(
              children: [
                if (course.isOngoing) ...[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: cs.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    course.courseName,
                    style: textTheme.titleSmall!.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: primaryTextColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (course.isOngoing) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: ShapeDecoration(
                      color: cs.primary.withValues(alpha: 0.10),
                      shape: const StadiumBorder(),
                    ),
                    child: Text(
                      '进行中',
                      style: textTheme.labelSmall!.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Text(
              course.locationText,
              style: textTheme.labelSmall!.copyWith(
                fontSize: 13,
                color: secondaryTextColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  /// 考试行：同课程行布局，时间列前以 error 色 event 图标标识。
  Widget _buildExamRow(
    BuildContext context,
    HomeTodayExamRow exam, {
    required Color primaryTextColor,
    required Color secondaryTextColor,
  }) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: _timeColumnWidth),
            // 外层 Row 的非 flex 子节点宽度无上界，内层不能再套 flex 子节点。
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.event_outlined, size: 14, color: cs.error),
                const SizedBox(width: 4),
                Text(
                  exam.timeText,
                  style: textTheme.labelSmall!.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: secondaryTextColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: _rowGap),
          Expanded(
            flex: 3,
            child: Text(
              exam.courseName,
              style: textTheme.titleSmall!.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: primaryTextColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Text(
              exam.locationText,
              style: textTheme.labelSmall!.copyWith(
                fontSize: 13,
                color: secondaryTextColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
