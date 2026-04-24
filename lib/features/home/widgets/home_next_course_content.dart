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
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: primaryTextColor,
        ),
      );
    }

    if (nextCourse == null) {
      return Text(
        '近期无课',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
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
        Transform.translate(
          offset: const Offset(-2, -4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: primaryTextColor.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: primaryTextColor.withValues(alpha: 0.20),
              ),
            ),
            child: Text(
              course.courseName,
              style: TextStyle(
                fontSize: 12,
                color: primaryTextColor.withValues(alpha: 0.95),
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            Icon(Icons.schedule, size: 14, color: secondaryTextColor),
            const SizedBox(width: 4),
            Text(
              whenText,
              style: TextStyle(fontSize: 13, color: secondaryTextColor),
            ),
            const SizedBox(width: 4),
            Text(
              '第 ${course.startLesson}-${course.endLesson} 节',
              style: TextStyle(fontSize: 11, color: tertiaryTextColor),
            ),
          ],
        ),
        const SizedBox(height: 4),
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
