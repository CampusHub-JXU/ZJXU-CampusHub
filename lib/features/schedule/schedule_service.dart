import 'package:dio/dio.dart';

import '../../core/network/dio_client.dart';
import '../../core/semester/semester_calendar.dart';
import 'schedule_model.dart';

class ScheduleRequestException implements Exception {
  const ScheduleRequestException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ScheduleAuthExpiredException extends ScheduleRequestException {
  const ScheduleAuthExpiredException() : super('登录状态已过期，请重新登录');
}

enum CourseChangeType { cancel, reschedule, makeup }

class CourseLessonSlot {
  const CourseLessonSlot({
    required this.week,
    required this.weekday,
    required this.startLesson,
    required this.endLesson,
  });

  final int week;
  final int weekday;
  final int startLesson;
  final int endLesson;

  bool overlaps(CourseEntry course) {
    if (weekday != course.weekday) return false;
    return course.startLesson <= endLesson && course.endLesson >= startLesson;
  }

  String get signature => '$week-$weekday-$startLesson-$endLesson';
}

class CourseChangeRule {
  const CourseChangeRule({
    required this.type,
    this.originalLesson,
    this.targetLesson,
    this.courseName,
    this.teacherName,
    this.classroom,
  });

  final CourseChangeType type;
  final CourseLessonSlot? originalLesson;
  final CourseLessonSlot? targetLesson;
  final String? courseName;
  final String? teacherName;
  final String? classroom;

  bool removesCourse(CourseEntry course, int week) {
    final lesson = originalLesson;
    if (lesson == null || lesson.week != week || !lesson.overlaps(course)) {
      return false;
    }

    final ruleCourseName = courseName?.trim() ?? '';
    if (ruleCourseName.isEmpty) return true;

    return _matchesCourseName(course.courseName, ruleCourseName);
  }

  bool addsCourseToWeek(int week) => targetLesson?.week == week;

  String get signature => [
    type.name,
    originalLesson?.signature ?? '',
    targetLesson?.signature ?? '',
    courseName ?? '',
    teacherName ?? '',
    classroom ?? '',
  ].join('|');
}

String _normalizeCourseName(String value) {
  return value.toLowerCase().replaceAll(
    RegExp('[\\s\\-—_（）()【】\\[\\]<>《》,，.。:：;；"\\\'、/+]+'),
    '',
  );
}

bool _matchesCourseName(String left, String right) {
  final a = _normalizeCourseName(left);
  final b = _normalizeCourseName(right);
  if (a.isEmpty || b.isEmpty) return false;
  return a.contains(b) || b.contains(a);
}

class ScheduleService {
  ScheduleService._();
  static final ScheduleService instance = ScheduleService._();

  final _dio = DioClient.instance.dio;

  int getCurrentWeek() {
    return SemesterCalendar.instance.weekForDate(DateTime.now());
  }

  Future<List<CourseEntry>> fetchSchedule(
    String studentId,
    int year,
    int term,
  ) async {
    final referer =
        'https://jwzx.zjxu.edu.cn/jwglxt/kbcx/xskbcx_cxXskbcxIndex.html'
        '?gnmkdm=N2151&layout=default&su=$studentId';

    final resp = await _dio.post<dynamic>(
      '/kbcx/xskbcx_cxXsKb.html',
      queryParameters: {'gnmkdm': 'N2151', 'su': studentId},
      data: 'xnm=$year&xqm=$term&kzlx=ck',
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        validateStatus: (status) => status != null && status < 1000,
        headers: {'Referer': referer, 'X-Requested-With': 'XMLHttpRequest'},
      ),
    );

    final statusCode = resp.statusCode ?? 0;
    if (statusCode == 901 || statusCode == 302 || statusCode == 303) {
      throw const ScheduleAuthExpiredException();
    }
    if (statusCode >= 400) {
      throw ScheduleRequestException('课表接口异常（状态码：$statusCode）');
    }

    final data = resp.data;
    if (data is! Map<String, dynamic>) {
      final raw = data?.toString() ?? '';
      if (_looksLikeLoginExpired(raw)) {
        throw const ScheduleAuthExpiredException();
      }
      throw const ScheduleRequestException('课表返回数据格式异常');
    }

    final message = data['message']?.toString() ?? '';
    if (_looksLikeLoginExpired(message)) {
      throw const ScheduleAuthExpiredException();
    }

    final kbList = data['kbList'] as List<dynamic>? ?? [];
    return kbList
        .cast<Map<String, dynamic>>()
        .map(CourseEntry.fromJson)
        .toList();
  }

  Future<List<CourseChangeRule>> fetchCourseChangeRules(
    String studentId,
  ) async {
    final messages = <String>{};
    messages.addAll(await _fetchInboxChangeMessages());

    final referer = 'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html';
    final resp = await _dio.post<String>(
      '/xtgl/index_cxAreaThree.html',
      queryParameters: {
        'localeKey': 'zh_CN',
        'gnmkdm': 'index',
        'su': studentId,
      },
      options: Options(
        responseType: ResponseType.plain,
        contentType: 'application/x-www-form-urlencoded;charset=UTF-8',
        validateStatus: (status) => status != null && status < 1000,
        headers: {'Referer': referer, 'X-Requested-With': 'XMLHttpRequest'},
      ),
    );

    final statusCode = resp.statusCode ?? 0;
    if (statusCode == 901 || statusCode == 302 || statusCode == 303) {
      throw const ScheduleAuthExpiredException();
    }
    if (statusCode >= 400) {
      throw ScheduleRequestException('课表调停课接口异常（状态码：$statusCode）');
    }

    final html = resp.data ?? '';
    if (_looksLikeLoginExpired(html)) {
      throw const ScheduleAuthExpiredException();
    }

    messages.addAll(_extractAreaThreeMessages(html));
    return parseCourseChangeMessages(messages);
  }

  Future<List<String>> _fetchInboxChangeMessages() async {
    final resp = await _dio.post<dynamic>(
      '/xtgl/index_cxDbsy.html',
      queryParameters: {'flag': '1'},
      options: Options(
        validateStatus: (status) => status != null && status < 1000,
        headers: {'X-Requested-With': 'XMLHttpRequest'},
      ),
    );

    final statusCode = resp.statusCode ?? 0;
    if (statusCode == 901 || statusCode == 302 || statusCode == 303) {
      throw const ScheduleAuthExpiredException();
    }
    if (statusCode >= 400) {
      throw ScheduleRequestException('教学消息接口异常（状态码：$statusCode）');
    }

    final data = resp.data;
    if (data is! Map<String, dynamic>) {
      final raw = data?.toString() ?? '';
      if (_looksLikeLoginExpired(raw)) {
        throw const ScheduleAuthExpiredException();
      }
      return const [];
    }

    final items = data['items'] as List<dynamic>? ?? const [];
    return items
        .cast<Map<String, dynamic>>()
        .map(
          (item) =>
              item['TKXX']?.toString() ??
              item['XXNR']?.toString() ??
              item['XXBT']?.toString() ??
              '',
        )
        .map((message) => _decodeHtmlEntities(message).trim())
        .where((message) => message.isNotEmpty)
        .toList();
  }

  List<CourseChangeRule> parseCourseChangeMessages(Iterable<String> messages) {
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
            _extractAdjustedTeacherName(message) ??
            _extractTeacherName(message),
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
    final segment = message.contains('调课到')
        ? message.split('调课到').last
        : message;
    final match = RegExp(
      r'第\s*\d+\s*周\s*星期[一二三四五六日天]\s*第\s*\d+(?:\s*[-~]\s*\d+)?\s*节(?:在|于)(.+?)上',
    ).firstMatch(segment);
    final classroom = match?.group(1)?.trim() ?? '';
    return classroom.isEmpty ? null : classroom;
  }

  List<String> _extractAreaThreeMessages(String html) {
    final messages = <String>[];
    final messagePattern = RegExp(r'data-tkxx="([^"]+)"');

    for (final match in messagePattern.allMatches(html)) {
      final encodedMessage = match.group(1) ?? '';
      final message = _decodeHtmlEntities(encodedMessage).trim();
      if (message.isNotEmpty) messages.add(message);
    }

    return messages;
  }

  List<CourseEntry> buildEffectiveWeekCourses({
    required List<CourseEntry> courses,
    required int week,
    List<CourseChangeRule> changeRules = const [],
  }) {
    final effectiveCourses = courses
        .where((course) => course.isInWeek(week))
        .where(
          (course) =>
              !changeRules.any((rule) => rule.removesCourse(course, week)),
        )
        .toList();

    for (final rule in changeRules.where(
      (rule) => rule.addsCourseToWeek(week),
    )) {
      final syntheticCourse = _buildSyntheticCourse(
        rule: rule,
        week: week,
        courses: courses,
      );
      if (syntheticCourse != null) {
        effectiveCourses.add(syntheticCourse);
      }
    }

    final deduped = <CourseEntry>[];
    final seen = <String>{};
    for (final course in effectiveCourses) {
      final signature = [
        course.courseName,
        course.teacherName,
        course.weekday,
        course.startLesson,
        course.endLesson,
        course.classroom,
        course.weekRange,
      ].join('|');
      if (seen.add(signature)) {
        deduped.add(course);
      }
    }

    return deduped;
  }

  CourseEntry? _buildSyntheticCourse({
    required CourseChangeRule rule,
    required int week,
    required List<CourseEntry> courses,
  }) {
    final targetLesson = rule.targetLesson;
    if (targetLesson == null || targetLesson.week != week) return null;

    final template = _findTemplateCourse(rule, courses);
    final courseName = (rule.courseName?.trim().isNotEmpty ?? false)
        ? rule.courseName!.trim()
        : template?.courseName ?? '调课课程';
    final teacherName = (rule.teacherName?.trim().isNotEmpty ?? false)
        ? rule.teacherName!.trim()
        : template?.teacherName ?? '';
    final classroom = (rule.classroom?.trim().isNotEmpty ?? false)
        ? rule.classroom!.trim()
        : template?.classroom ?? '';

    return CourseEntry(
      courseName: courseName,
      teacherName: teacherName,
      weekday: targetLesson.weekday,
      startLesson: targetLesson.startLesson,
      endLesson: targetLesson.endLesson,
      weekRange: '$week周',
      classroom: classroom,
      campus: template?.campus ?? '',
      typeSymbol: template?.typeSymbol ?? '',
    );
  }

  CourseEntry? _findTemplateCourse(
    CourseChangeRule rule,
    List<CourseEntry> courses,
  ) {
    final lesson = rule.originalLesson;
    final ruleCourseName = rule.courseName?.trim() ?? '';

    if (lesson != null) {
      for (final course in courses) {
        if (!course.isInWeek(lesson.week) || !lesson.overlaps(course)) {
          continue;
        }
        if (ruleCourseName.isEmpty ||
            _matchesCourseName(course.courseName, ruleCourseName)) {
          return course;
        }
      }
    }

    if (ruleCourseName.isNotEmpty) {
      for (final course in courses) {
        if (_matchesCourseName(course.courseName, ruleCourseName)) {
          return course;
        }
      }
    }

    return null;
  }

  int? _weekdayToInt(String text) {
    return switch (text) {
      '一' => 1,
      '二' => 2,
      '三' => 3,
      '四' => 4,
      '五' => 5,
      '六' => 6,
      '日' || '天' => 7,
      _ => null,
    };
  }

  String _decodeHtmlEntities(String value) {
    return value
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&');
  }

  bool _looksLikeLoginExpired(String text) {
    final value = text.toLowerCase();
    return value.contains('登录') ||
        value.contains('登陆') ||
        value.contains('session') ||
        value.contains('expired') ||
        value.contains('请先登录') ||
        value.contains('重新登录');
  }
}
