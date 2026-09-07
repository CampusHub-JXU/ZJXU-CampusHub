import 'schedule_model.dart';
import 'schedule_term_context.dart';

enum CourseChangeType { cancel, reschedule, makeup }

class ScheduleChangeMessage {
  const ScheduleChangeMessage({required this.message, this.publishedAt});

  final String message;
  final DateTime? publishedAt;

  String get dedupKey => message.trim().replaceAll(RegExp(r'\s+'), ' ');
}

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

  Map<String, dynamic> toJson() => {
    'week': week,
    'weekday': weekday,
    'startLesson': startLesson,
    'endLesson': endLesson,
  };

  factory CourseLessonSlot.fromJson(Map<String, dynamic> json) {
    return CourseLessonSlot(
      week: json['week'] as int? ?? 0,
      weekday: json['weekday'] as int? ?? 0,
      startLesson: json['startLesson'] as int? ?? 0,
      endLesson: json['endLesson'] as int? ?? 0,
    );
  }
}

class CourseChangeRule {
  const CourseChangeRule({
    required this.type,
    this.originalLesson,
    this.targetLesson,
    this.courseName,
    this.teacherName,
    this.classroom,
    this.originalClassroom,
    this.rawMessage,
    this.publishedAt,
    this.termContext,
  });

  final CourseChangeType type;
  final CourseLessonSlot? originalLesson;
  final CourseLessonSlot? targetLesson;
  final String? courseName;
  final String? teacherName;

  /// 通知中的原教室；[classroom] 是通知中的目标教室。
  final String? originalClassroom;
  final String? classroom;

  /// 服务器通知的原文，供未应用通知继续展示。
  final String? rawMessage;
  final DateTime? publishedAt;
  final ScheduleTermContext? termContext;

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
    originalClassroom ?? '',
    classroom ?? '',
    rawMessage ?? '',
    termContext?.key ?? '',
  ].join('|');

  /// 用于把同一条多周通知的按周规则合并成一条展示项。
  String get noticeSignature => [
    type.name,
    originalLesson == null
        ? ''
        : '${originalLesson!.weekday}-${originalLesson!.startLesson}-${originalLesson!.endLesson}',
    targetLesson == null
        ? ''
        : '${targetLesson!.weekday}-${targetLesson!.startLesson}-${targetLesson!.endLesson}',
    courseName ?? '',
    teacherName ?? '',
    originalClassroom ?? '',
    classroom ?? '',
    rawMessage ?? '',
    termContext?.key ?? '',
  ].join('|');

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'originalLesson': originalLesson?.toJson(),
    'targetLesson': targetLesson?.toJson(),
    'courseName': courseName,
    'teacherName': teacherName,
    'originalClassroom': originalClassroom,
    'classroom': classroom,
    'rawMessage': rawMessage,
    'publishedAt': publishedAt?.millisecondsSinceEpoch,
    'termContext': termContext?.toJson(),
  };

  factory CourseChangeRule.fromJson(Map<String, dynamic> json) {
    return CourseChangeRule(
      type: CourseChangeType.values.firstWhere(
        (value) => value.name == json['type'],
        orElse: () => CourseChangeType.cancel,
      ),
      originalLesson: _slotFromJson(json['originalLesson']),
      targetLesson: _slotFromJson(json['targetLesson']),
      courseName: json['courseName']?.toString(),
      teacherName: json['teacherName']?.toString(),
      originalClassroom: json['originalClassroom']?.toString(),
      classroom: json['classroom']?.toString(),
      rawMessage: json['rawMessage']?.toString(),
      publishedAt: _dateFromMillis(json['publishedAt']),
      termContext: _termContextFromJson(json['termContext']),
    );
  }

  static CourseLessonSlot? _slotFromJson(Object? value) {
    if (value is Map<String, dynamic>) {
      return CourseLessonSlot.fromJson(value);
    }
    return null;
  }

  static ScheduleTermContext? _termContextFromJson(Object? value) {
    if (value is Map<String, dynamic>) {
      final context = ScheduleTermContext.fromJson(value);
      if (context.academicYear > 0 &&
          (context.term == 3 || context.term == 12)) {
        return context;
      }
    }
    return null;
  }

  static DateTime? _dateFromMillis(Object? value) {
    final millis = value is int ? value : int.tryParse(value?.toString() ?? '');
    if (millis == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }
}

enum CourseChangeNoticeStatus { reflected, unapplied }

/// 面向通知列表的逻辑展示数据；同一原文的多周规则只保留一项。
class CourseChangeNotice {
  const CourseChangeNotice({
    required this.rule,
    required this.status,
    this.effectiveCourse,
  });

  final CourseChangeRule rule;
  final CourseChangeNoticeStatus status;
  final CourseEntry? effectiveCourse;

  String? get rawMessage => rule.rawMessage;
  String? get originalClassroom => rule.originalClassroom;
  String? get newClassroom => rule.classroom;
  String? get effectiveClassroom => effectiveCourse?.classroom;
  ScheduleTermContext? get termContext => rule.termContext;
  bool get isReflected => status == CourseChangeNoticeStatus.reflected;
  bool get isUnapplied => status == CourseChangeNoticeStatus.unapplied;

  String get statusLabel => isReflected ? '当前课表已体现' : '未应用';

  String get statusDetail {
    if (isReflected) return '当前课表已体现';
    if (rule.termContext == null) return '学期未确认，未应用';
    return '当前课表未体现';
  }
}

String normalizeCourseName(String value) {
  return value.toLowerCase().replaceAll(
    RegExp('[\\s\\-—_（）()【】\\[\\]<>《》,，.。:：;；"\\\'、/+]+'),
    '',
  );
}

bool _matchesCourseName(String left, String right) {
  final a = normalizeCourseName(left);
  final b = normalizeCourseName(right);
  if (a.isEmpty || b.isEmpty) return false;
  return a.contains(b) || b.contains(a);
}
