part of 'schedule_service.dart';

/// 调课/换教室/停课/补课提醒消息解析（纯函数）。

List<CourseChangeRule> parseScheduleChangeMessages(Iterable<String> messages) {
  return parseScheduleChangeMessageEntries(
    messages.map((message) => ScheduleChangeMessage(message: message)),
  );
}

List<CourseChangeRule> parseScheduleChangeMessageEntries(
  Iterable<ScheduleChangeMessage> messages,
) {
  final rules = <CourseChangeRule>[];
  final seen = <String>{};
  final selectedMessages = <String, ScheduleChangeMessage>{};

  for (final entry in messages) {
    final message = entry.message.trim();
    if (!message.contains('调课提醒') &&
        !message.contains('换教室提醒') &&
        !message.contains('停课提醒') &&
        !message.contains('补课提醒')) {
      continue;
    }

    final key = entry.dedupKey;
    final existing = selectedMessages[key];
    if (existing == null ||
        (existing.publishedAt == null && entry.publishedAt != null)) {
      selectedMessages[key] = ScheduleChangeMessage(
        message: message,
        publishedAt: entry.publishedAt,
      );
    }
  }

  for (final entry in selectedMessages.values) {
    for (final rule in _parseCourseChangeRules(
      entry.message,
      publishedAt: entry.publishedAt,
    )) {
      if (seen.add(rule.signature)) rules.add(rule);
    }
  }

  return rules;
}

List<CourseChangeRule> filterScheduleChangeRulesForTerm(
  Iterable<CourseChangeRule> rules,
  ScheduleTermContext termContext,
) {
  return rules.where((rule) => rule.termContext == termContext).toList();
}

List<String> extractScheduleChangeMessagesFromAreaThreeHtml(String html) {
  return extractScheduleChangeMessageEntriesFromAreaThreeHtml(html)
      .map((entry) => entry.message)
      .toList();
}

List<ScheduleChangeMessage>
extractScheduleChangeMessageEntriesFromAreaThreeHtml(String html) {
  final messages = <ScheduleChangeMessage>[];
  final seen = <String>{};

  final fragment = html_parser.parseFragment(html);
  for (final element in fragment.querySelectorAll('a')) {
    if (!element.attributes.containsKey('data-tkxx')) continue;
    final message = element.attributes['data-tkxx']?.trim() ?? '';
    if (message.isEmpty) continue;
    var dateText = element.querySelector('span.fraction')?.text.trim() ?? '';
    if (dateText.isEmpty) {
      // Some html package versions do not match the class selector reliably;
      // stay inside this anchor rather than borrowing a sibling's date.
      dateText =
          RegExp(r'\d{4}-\d{1,2}-\d{1,2}(?:\s+\d{1,2}:\d{1,2}(?::\d{1,2})?)?')
              .firstMatch(element.text)
              ?.group(0) ??
          '';
    }
    final entry = ScheduleChangeMessage(
      message: message,
      publishedAt: parseScheduleChangePublishedAt(dateText),
    );
    if (seen.add(entry.dedupKey)) messages.add(entry);
  }

  // Keep compatibility with deployments that return data-tkxx outside an anchor.
  for (final element in fragment.querySelectorAll('[data-tkxx]')) {
    final message = element.attributes['data-tkxx']?.trim() ?? '';
    final entry = ScheduleChangeMessage(message: message);
    if (message.isNotEmpty && seen.add(entry.dedupKey)) messages.add(entry);
  }

  return messages;
}

DateTime? parseScheduleChangePublishedAt(String value) {
  final match = RegExp(
    r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:\s+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$',
  ).firstMatch(value.trim());
  if (match == null) return null;

  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.tryParse(match.group(4) ?? '0') ?? 0;
  final minute = int.tryParse(match.group(5) ?? '0') ?? 0;
  final second = int.tryParse(match.group(6) ?? '0') ?? 0;
  final date = DateTime(year, month, day, hour, minute, second);
  if (date.year != year ||
      date.month != month ||
      date.day != day ||
      date.hour != hour ||
      date.minute != minute ||
      date.second != second) {
    return null;
  }
  return date;
}

List<CourseChangeRule> _parseCourseChangeRules(
  String message, {
  DateTime? publishedAt,
}) {
  final lessons = _extractLessonInfos(message);
  final courseName = _extractCourseName(message);
  final termContext = _extractTermContext(message);

  if (message.contains('调课提醒')) {
    final originalLesson = lessons.isNotEmpty ? lessons.first : null;
    final targetLesson = lessons.length > 1 ? lessons[1] : null;
    if (originalLesson == null) return const [];

    return [
      CourseChangeRule(
        type: targetLesson == null
            ? CourseChangeType.cancel
            : CourseChangeType.reschedule,
        originalLesson: originalLesson,
        targetLesson: targetLesson,
        courseName: courseName,
        teacherName:
            _extractAdjustedTeacherName(message) ??
            _extractTeacherName(message),
        originalClassroom: _extractOriginalClassroom(message),
        classroom: _extractAdjustedClassroom(message),
        rawMessage: message,
        publishedAt: publishedAt,
        termContext: termContext,
      ),
    ];
  }

  if (message.contains('换教室提醒')) {
    final classroom = _extractAdjustedClassroom(message);
    if (classroom == null) return const [];
    return [
      for (final lesson in lessons)
        CourseChangeRule(
          type: CourseChangeType.reschedule,
          originalLesson: lesson,
          targetLesson: lesson,
          courseName: courseName,
          teacherName: _extractTeacherName(message),
          originalClassroom: _extractOriginalClassroom(message),
          classroom: classroom,
          rawMessage: message,
          publishedAt: publishedAt,
          termContext: termContext,
        ),
    ];
  }

  if (message.contains('停课提醒')) {
    final originalLesson = lessons.isNotEmpty ? lessons.first : null;
    if (originalLesson == null) return const [];

    return [
      CourseChangeRule(
        type: CourseChangeType.cancel,
        originalLesson: originalLesson,
        courseName: courseName,
        originalClassroom: _extractOriginalClassroom(message),
        rawMessage: message,
        publishedAt: publishedAt,
        termContext: termContext,
      ),
    ];
  }

  if (message.contains('补课提醒')) {
    final targetLesson = lessons.isNotEmpty ? lessons.first : null;
    if (targetLesson == null) return const [];

    return [
      CourseChangeRule(
        type: CourseChangeType.makeup,
        targetLesson: targetLesson,
        courseName: courseName,
        teacherName: _extractTeacherName(message),
        originalClassroom: _extractOriginalClassroom(message),
        classroom: _extractAdjustedClassroom(message),
        rawMessage: message,
        publishedAt: publishedAt,
        termContext: termContext,
      ),
    ];
  }

  return const [];
}

List<CourseLessonSlot> _extractLessonInfos(String message) {
  final slots = <CourseLessonSlot>[];
  final pattern = RegExp(
    r'第\s*([0-9\s,~\-周]+?)\s*星期([一二三四五六日天])\s*第\s*(\d+)(?:\s*[-~]\s*(\d+))?\s*节',
  );

  for (final match in pattern.allMatches(message)) {
    final weeks = _expandWeekText(match.group(1) ?? '');
    final weekday = _weekdayToInt(match.group(2) ?? '');
    final startLesson = int.tryParse(match.group(3) ?? '');
    final endLesson = int.tryParse(match.group(4) ?? match.group(3) ?? '');
    if (weeks.isEmpty ||
        weekday == null ||
        startLesson == null ||
        endLesson == null) {
      continue;
    }

    for (final week in weeks) {
      slots.add(
        CourseLessonSlot(
          week: week,
          weekday: weekday,
          startLesson: startLesson,
          endLesson: endLesson,
        ),
      );
    }
  }

  return slots;
}

String? _extractCourseName(String message) {
  final patterns = [
    RegExp(r'上的(.+?)课程调课'),
    RegExp(r'上的(.+?)课程现改为'),
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
  final match = RegExp(r'(?:调课提醒|换教室提醒|补课提醒|停课提醒)[:：]?\s*(?:原定)?(.+?)老师')
      .firstMatch(message);
  final name = match?.group(1)?.trim() ?? '';
  return name.isEmpty ? null : name;
}

String? _extractAdjustedTeacherName(String message) {
  final match = RegExp(r'调课到由(.+?)老师').firstMatch(message);
  final name = match?.group(1)?.trim() ?? '';
  return name.isEmpty ? null : name;
}

String? _extractAdjustedClassroom(String message) {
  final changedClassroom = RegExp(r'改为在(.+?)上课')
      .firstMatch(message)
      ?.group(1)
      ?.trim();
  if (changedClassroom != null && changedClassroom.isNotEmpty) {
    return changedClassroom;
  }

  final segment = message.contains('调课到') ? message.split('调课到').last : message;
  final match = RegExp(
    r'第\s*\d+\s*周\s*星期[一二三四五六日天]\s*第\s*\d+(?:\s*[-~]\s*\d+)?\s*节(?:在|于)(.+?)上',
  ).firstMatch(segment);
  final classroom = match?.group(1)?.trim() ?? '';
  return classroom.isEmpty ? null : classroom;
}

String? _extractOriginalClassroom(String message) {
  final match = RegExp(
    r'第\s*[0-9\s,~\-周]+?\s*星期[一二三四五六日天]\s*第\s*\d+(?:\s*[-~]\s*\d+)?\s*节(?:在|于)?(.+?)上的',
  ).firstMatch(message);
  final classroom = match?.group(1)?.trim() ?? '';
  return classroom.isEmpty ? null : classroom;
}

List<int> _expandWeekText(String value) {
  final weeks = <int>[];
  for (final part in value.replaceAll('周', '').split(',')) {
    final bounds = part.trim().split(RegExp(r'[-~]'));
    final start = int.tryParse(bounds.first.trim());
    final end = int.tryParse(
      (bounds.length > 1 ? bounds.last : bounds.first).trim(),
    );
    if (start == null ||
        end == null ||
        start < 1 ||
        end < start ||
        end - start > 51) {
      continue;
    }
    for (var week = start; week <= end; week++) {
      weeks.add(week);
    }
  }
  return weeks;
}

ScheduleTermContext? _extractTermContext(String message) {
  final match = RegExp(
    r'(\d{4})\s*[-—]\s*(\d{4})\s*学年\s*(?:第\s*)?(一|二|1|2)\s*学期',
  ).firstMatch(message);
  if (match == null) return null;
  final year = int.tryParse(match.group(1)!);
  final nextYear = int.tryParse(match.group(2)!);
  final term = switch (match.group(3)) {
    '一' || '1' => 3,
    '二' || '2' => 12,
    _ => null,
  };
  if (year == null || nextYear != year + 1 || term == null) return null;
  return ScheduleTermContext(academicYear: year, term: term);
}
