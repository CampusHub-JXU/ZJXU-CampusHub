part of 'schedule_service.dart';

/// 调课/停课/补课提醒消息解析（纯函数，供 [ScheduleService] 委托调用）。

List<CourseChangeRule> parseScheduleChangeMessages(Iterable<String> messages) {
  final rules = <CourseChangeRule>[];
  final seen = <String>{};

  for (final rawMessage in messages) {
    final message = rawMessage.trim();
    if (!message.contains('调课提醒') &&
        !message.contains('停课提醒') &&
        !message.contains('补课提醒')) {
      continue;
    }

    final rule = _parseCourseChangeRule(message);
    if (rule == null || !seen.add(rule.signature)) continue;
    rules.add(rule);
  }

  return rules;
}

CourseChangeRule? _parseCourseChangeRule(String message) {
  final lessons = _extractLessonInfos(message);
  final courseName = _extractCourseName(message);

  if (message.contains('调课提醒')) {
    final originalLesson = lessons.isNotEmpty ? lessons.first : null;
    final targetLesson = lessons.length > 1 ? lessons[1] : null;
    if (originalLesson == null) return null;

    return CourseChangeRule(
      type: targetLesson == null
          ? CourseChangeType.cancel
          : CourseChangeType.reschedule,
      originalLesson: originalLesson,
      targetLesson: targetLesson,
      courseName: courseName,
      teacherName:
          _extractAdjustedTeacherName(message) ?? _extractTeacherName(message),
      classroom: _extractAdjustedClassroom(message),
    );
  }

  if (message.contains('停课提醒')) {
    final originalLesson = lessons.isNotEmpty ? lessons.first : null;
    if (originalLesson == null) return null;

    return CourseChangeRule(
      type: CourseChangeType.cancel,
      originalLesson: originalLesson,
      courseName: courseName,
    );
  }

  if (message.contains('补课提醒')) {
    final targetLesson = lessons.isNotEmpty ? lessons.first : null;
    if (targetLesson == null) return null;

    return CourseChangeRule(
      type: CourseChangeType.makeup,
      targetLesson: targetLesson,
      courseName: courseName,
      teacherName: _extractTeacherName(message),
      classroom: _extractAdjustedClassroom(message),
    );
  }

  return null;
}

List<CourseLessonSlot> _extractLessonInfos(String message) {
  final slots = <CourseLessonSlot>[];
  final pattern = RegExp(
    r'第\s*(\d+)\s*周\s*星期([一二三四五六日天])\s*第\s*(\d+)(?:\s*[-~]\s*(\d+))?\s*节',
  );

  for (final match in pattern.allMatches(message)) {
    final week = int.tryParse(match.group(1) ?? '');
    final weekday = _weekdayToInt(match.group(2) ?? '');
    final startLesson = int.tryParse(match.group(3) ?? '');
    final endLesson = int.tryParse(match.group(4) ?? match.group(3) ?? '');
    if (week == null ||
        weekday == null ||
        startLesson == null ||
        endLesson == null) {
      continue;
    }

    slots.add(
      CourseLessonSlot(
        week: week,
        weekday: weekday,
        startLesson: startLesson,
        endLesson: endLesson,
      ),
    );
  }

  return slots;
}

String? _extractCourseName(String message) {
  final patterns = [
    RegExp(r'上的(.+?)课程调课'),
    RegExp(r'对课程(.+?)进行停课'),
    RegExp(r'上的(.+?)课程停课'),
    RegExp(r'对课程(.+?)进行补课'),
    RegExp(r'上的(.+?)课程进行补课'),
  ];

  for (final pattern in patterns) {
    final match = pattern.firstMatch(message);
    final name = match?.group(1)?.trim() ?? '';
    if (name.isNotEmpty) return name;
  }

  return null;
}

String? _extractTeacherName(String message) {
  final match = RegExp(
    r'(?:调课提醒|补课提醒|停课提醒)[:：]?\s*(?:原定)?(.+?)老师',
  ).firstMatch(message);
  final name = match?.group(1)?.trim() ?? '';
  return name.isEmpty ? null : name;
}

String? _extractAdjustedTeacherName(String message) {
  final match = RegExp(r'调课到由(.+?)老师').firstMatch(message);
  final name = match?.group(1)?.trim() ?? '';
  return name.isEmpty ? null : name;
}

String? _extractAdjustedClassroom(String message) {
  final segment = message.contains('调课到') ? message.split('调课到').last : message;
  final match = RegExp(
    r'第\s*\d+\s*周\s*星期[一二三四五六日天]\s*第\s*\d+(?:\s*[-~]\s*\d+)?\s*节(?:在|于)(.+?)上',
  ).firstMatch(segment);
  final classroom = match?.group(1)?.trim() ?? '';
  return classroom.isEmpty ? null : classroom;
}
