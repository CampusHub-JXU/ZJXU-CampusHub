import 'package:flutter/material.dart';

import '../../../app/app_theme_controller.dart';
import '../models/home_presentation.dart';

/// Today Section：当天剩余课程 + 今日考试的紧凑列表。
///
/// 左对齐 Section 标题，无卡片嵌套，仅行间极轻分隔；
/// 无内容时单行「暂无安排」，不做大空态卡。
class HomeTodaySection extends StatelessWidget {
  const HomeTodaySection({super.key, required this.today});

  final HomeTodayPresentation today;

  @override
  Widget build(BuildContext context) {
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
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            '今天',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: primaryTextColor,
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (today.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 2, bottom: 2),
            child: Text(
              '暂无安排',
              style: TextStyle(fontSize: 13, color: secondaryTextColor),
            ),
          )
        else ...[
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
      ],
    );
  }

  Widget _buildDivider(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: cs.onSurface.withValues(alpha: 0.06),
    );
  }

  Widget _buildCourseRow(
    BuildContext context,
    HomeTodayCourseRow course, {
    required Color primaryTextColor,
    required Color secondaryTextColor,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 52),
            child: Text(
              course.timeText,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: course.isOngoing ? cs.primary : secondaryTextColor,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  course.courseName,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: primaryTextColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${course.locationText} · ${course.lessonText}',
                  style: TextStyle(fontSize: 12, color: secondaryTextColor),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (course.isOngoing) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '进行中',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: cs.primary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildExamRow(
    BuildContext context,
    HomeTodayExamRow exam, {
    required Color primaryTextColor,
    required Color secondaryTextColor,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 52),
            child: Text(
              exam.timeText,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: secondaryTextColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  exam.courseName,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: primaryTextColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  exam.locationText,
                  style: TextStyle(fontSize: 12, color: secondaryTextColor),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: cs.error.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '考试',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: cs.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
