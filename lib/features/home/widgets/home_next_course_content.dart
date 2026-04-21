import 'package:flutter/material.dart';

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
    if (!courseLoggedIn) {
      return const Text(
        '登录后查看课程',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      );
    }

    if (nextCourse == null) {
      return const Text(
        '近期无课',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: Colors.white,
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
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
            ),
            child: Text(
              course.courseName,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.95),
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
            Icon(
              Icons.schedule,
              size: 14,
              color: Colors.white.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 4),
            Text(
              whenText,
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '第 ${course.startLesson}-${course.endLesson} 节',
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(
              Icons.location_on_outlined,
              size: 14,
              color: Colors.white.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                locationText,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
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
