import 'package:flutter/material.dart';

import '../../../app/app_theme_controller.dart';
import '../../schedule/schedule_model.dart';

class HomeNextCourseContent extends StatelessWidget {
  const HomeNextCourseContent({
    super.key,
    required this.courseLoggedIn,
    required this.nextCourse,
    required this.nextCourseLabel,
    required this.timeRangeText,
    required this.locationText,
  });

  final bool courseLoggedIn;
  final CourseEntry? nextCourse;
  final String nextCourseLabel;
  final String timeRangeText;
  final String locationText;

  @override
  Widget build(BuildContext context) {
    final primaryTextColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      Colors.white,
    );
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(
          context,
          Colors.white.withValues(alpha: 0.90),
        );
    final tertiaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(
          context,
          Colors.white.withValues(alpha: 0.60),
        );
    if (!courseLoggedIn) {
      return Text(
        '登录后查看课程',
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w800,
          color: primaryTextColor,
        ),
      );
    }

    if (nextCourse == null) {
      return Text(
        '近期无课',
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w800,
          color: primaryTextColor,
        ),
      );
    }

    final course = nextCourse!;
    final whenText = nextCourseLabel.isEmpty
        ? timeRangeText
        : '$nextCourseLabel $timeRangeText';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          constraints: const BoxConstraints(maxWidth: 210),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: primaryTextColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: primaryTextColor.withValues(alpha: 0.18)),
          ),
          child: Text(
            course.courseName,
            style: TextStyle(
              fontSize: 12,
              color: primaryTextColor.withValues(alpha: 0.96),
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.schedule_rounded, size: 14, color: secondaryTextColor),
            const SizedBox(width: 5),
            Text(
              whenText,
              style: TextStyle(
                fontSize: 13,
                color: secondaryTextColor,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              '第 ${course.startLesson}-${course.endLesson} 节',
              style: TextStyle(fontSize: 12, color: tertiaryTextColor),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(
              Icons.location_on_outlined,
              size: 14,
              color: secondaryTextColor,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                locationText,
                style: TextStyle(fontSize: 13, color: secondaryTextColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
