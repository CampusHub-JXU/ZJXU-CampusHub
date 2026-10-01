import 'schedule_model.dart';
import 'schedule_change_rule.dart';
import '../../core/semester/schedule_term_context.dart';

class ScheduleCacheSnapshot {
  const ScheduleCacheSnapshot({
    required this.studentId,
    required this.termContext,
    this.courses = const [],
    this.changeRules = const [],
    this.scheduleUpdatedAt,
    this.changeRulesUpdatedAt,
    this.changeRulesCurrentScoped = false,
    this.changeRulesDateAware = true,
  });

  final String studentId;
  final ScheduleTermContext termContext;
  final List<CourseEntry> courses;
  final List<CourseChangeRule> changeRules;
  final DateTime? scheduleUpdatedAt;
  final DateTime? changeRulesUpdatedAt;

  /// 仅由当前学期上下文抓取后写入；这不是消息本身的学期证明。
  final bool changeRulesCurrentScoped;

  /// Missing in the pre-date schema; such snapshots must refresh once.
  final bool changeRulesDateAware;

  bool get hasData =>
      courses.isNotEmpty ||
      changeRules.isNotEmpty ||
      scheduleUpdatedAt != null ||
      changeRulesUpdatedAt != null;

  DateTime? get lastUpdatedAt {
    final values = [
      ...?scheduleUpdatedAt == null ? null : [scheduleUpdatedAt],
      ...?changeRulesUpdatedAt == null ? null : [changeRulesUpdatedAt],
    ]..sort();
    return values.isEmpty ? null : values.last;
  }

  bool needsScheduleRefresh(
    DateTime now, {
    Duration maxAge = const Duration(days: 7),
  }) {
    final updatedAt = scheduleUpdatedAt;
    if (updatedAt == null || courses.isEmpty) return true;
    return now.difference(updatedAt) >= maxAge;
  }

  bool needsChangeRulesRefresh(
    DateTime now, {
    Duration maxAge = const Duration(days: 1),
  }) {
    final updatedAt = changeRulesUpdatedAt;
    if (updatedAt == null) return true;
    if (changeRules.isNotEmpty && !changeRulesDateAware) return true;
    return now.difference(updatedAt) >= maxAge;
  }

  ScheduleCacheSnapshot copyWith({
    String? studentId,
    ScheduleTermContext? termContext,
    List<CourseEntry>? courses,
    List<CourseChangeRule>? changeRules,
    DateTime? scheduleUpdatedAt,
    DateTime? changeRulesUpdatedAt,
    bool? changeRulesCurrentScoped,
    bool? changeRulesDateAware,
    bool clearScheduleUpdatedAt = false,
    bool clearChangeRulesUpdatedAt = false,
  }) {
    return ScheduleCacheSnapshot(
      studentId: studentId ?? this.studentId,
      termContext: termContext ?? this.termContext,
      courses: courses ?? this.courses,
      changeRules: changeRules ?? this.changeRules,
      scheduleUpdatedAt: clearScheduleUpdatedAt
          ? null
          : scheduleUpdatedAt ?? this.scheduleUpdatedAt,
      changeRulesUpdatedAt: clearChangeRulesUpdatedAt
          ? null
          : changeRulesUpdatedAt ?? this.changeRulesUpdatedAt,
      changeRulesCurrentScoped:
          changeRulesCurrentScoped ?? this.changeRulesCurrentScoped,
      changeRulesDateAware: changeRulesDateAware ?? this.changeRulesDateAware,
    );
  }

  Map<String, dynamic> toJson() => {
    'studentId': studentId,
    'termContext': termContext.toJson(),
    'courses': courses.map((course) => course.toJson()).toList(),
    'changeRules': changeRules.map((rule) => rule.toJson()).toList(),
    'scheduleUpdatedAt': scheduleUpdatedAt?.millisecondsSinceEpoch,
    'changeRulesUpdatedAt': changeRulesUpdatedAt?.millisecondsSinceEpoch,
    'changeRulesCurrentScoped': changeRulesCurrentScoped,
    'changeRulesDateAware': changeRulesDateAware,
  };

  factory ScheduleCacheSnapshot.fromJson(Map<String, dynamic> json) {
    final courseList = json['courses'] as List<dynamic>? ?? const [];
    final changeRuleList = json['changeRules'] as List<dynamic>? ?? const [];

    return ScheduleCacheSnapshot(
      studentId: json['studentId']?.toString() ?? '',
      termContext: ScheduleTermContext.fromJson(
        json['termContext'] as Map<String, dynamic>? ?? const {},
      ),
      courses: courseList
          .whereType<Map<String, dynamic>>()
          .map(CourseEntry.fromJson)
          .toList(),
      changeRules: changeRuleList
          .whereType<Map<String, dynamic>>()
          .map(CourseChangeRule.fromJson)
          .toList(),
      scheduleUpdatedAt: dateFromEpochMillis(json['scheduleUpdatedAt']),
      changeRulesUpdatedAt: dateFromEpochMillis(json['changeRulesUpdatedAt']),
      changeRulesCurrentScoped: json['changeRulesCurrentScoped'] == true,
      changeRulesDateAware: json.containsKey('changeRulesDateAware')
          ? json['changeRulesDateAware'] == true
          : false,
    );
  }

  static ScheduleCacheSnapshot empty({
    required String studentId,
    required ScheduleTermContext termContext,
  }) {
    return ScheduleCacheSnapshot(
      studentId: studentId,
      termContext: termContext,
    );
  }
}
