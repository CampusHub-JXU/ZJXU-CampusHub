import '../semester/schedule_term_context.dart';
import 'schedule_change_rule.dart' show dateFromEpochMillis, matchesCourseName;
import 'schedule_model.dart';

/// 特定日期课程编辑（不可变值对象）。
///
/// 用户在课表页对「某一次课」（源周次 + 星期 + 节次段 + 课名定位的
/// `CourseEntry`）做的本地修改：移动时间 / 改教室 / 改老师。
///
/// - 源侧（`source*`）是**被编辑时的原课程状态**，永远指向权威课表里那条
///   原始课程；对同一原课程再次编辑必须替换旧 override（见
///   [sourceSignature]），绝不叠加。
/// - 目标侧（`target*`）是合成 `CourseEntry` 落到的周次 / 星期 / 节次段，
///   `targetClassroom` / `targetTeacherName` 是编辑后的展示值。
/// - `termContext` 为 null 表示未证明学期，随所在快照的学期上下文生效
///   （与 `CourseChangeRule.termContext == null` 的展示层语义一致）。
/// - 持久化进 `ScheduleCacheSnapshot.dateOverrides`，与课表 / 调课规则一同
///   按 owner + 学期缓存键隔离；网络刷新绝不冲掉（由 `copyWith` 保留）。
class ScheduleDateOverride {
  const ScheduleDateOverride({
    required this.id,
    this.termContext,
    required this.sourceDate,
    required this.sourceWeek,
    required this.sourceWeekday,
    required this.sourceStartLesson,
    required this.sourceEndLesson,
    required this.sourceCourseName,
    this.sourceTeacherName = '',
    this.sourceClassroom = '',
    required this.targetDate,
    required this.targetWeek,
    required this.targetWeekday,
    required this.targetStartLesson,
    required this.targetEndLesson,
    this.targetClassroom = '',
    this.targetTeacherName = '',
    required this.updatedAt,
  });

  final String id;
  final ScheduleTermContext? termContext;

  /// 编辑时该次课所在日期（`yyyy-MM-dd`）。
  final String sourceDate;
  final int sourceWeek;
  final int sourceWeekday;
  final int sourceStartLesson;
  final int sourceEndLesson;
  final String sourceCourseName;
  final String sourceTeacherName;
  final String sourceClassroom;

  /// 编辑后该次课落到的日期（`yyyy-MM-dd`）。
  final String targetDate;
  final int targetWeek;
  final int targetWeekday;
  final int targetStartLesson;
  final int targetEndLesson;
  final String targetClassroom;
  final String targetTeacherName;

  /// 最近一次编辑时间。
  final DateTime updatedAt;

  /// 源周：权威课表中位于 [sourceWeekday] / [sourceStartLesson]-
  /// [sourceEndLesson] 节次段且课名一致的那条课程就是本 override 的「原课程」。
  ///
  /// 周次归属仍以 `CourseEntry.isInWeek`（`weekRange` / 单双周）为准：
  /// 权威数据里 weekRange 不覆盖 [week] 时，override 不生效。
  bool matchesSource(int week, CourseEntry course) {
    if (week != sourceWeek || !course.isInWeek(week)) return false;
    if (course.weekday != sourceWeekday) return false;
    if (course.startLesson != sourceStartLesson ||
        course.endLesson != sourceEndLesson) {
      return false;
    }
    return matchesCourseName(course.courseName, sourceCourseName);
  }

  /// 目标周：识别由本 override 合成出的展示课程（落在
  /// [targetWeekday] / [targetStartLesson]-[targetEndLesson]，课名沿用
  /// [sourceCourseName]）。「再次编辑一条被编辑过的课」经此命中，UI 可据此
  /// 用源侧字段定位原课程并重写同一条 override。
  bool matchesTarget(int week, CourseEntry course) {
    if (week != targetWeek) return false;
    if (course.weekday != targetWeekday) return false;
    if (course.startLesson != targetStartLesson ||
        course.endLesson != targetEndLesson) {
      return false;
    }
    return matchesCourseName(course.courseName, sourceCourseName);
  }

  /// 同一「原课程」的稳定标识：源周 + 源星期 + 源节次段 + 规范化源课名。
  ///
  /// `id` 每次新建随机生成，不能承担去重职责；重复编辑同一原课程必须按本
  /// 签名**覆盖更新**，否则合成列表会叠加多条。故意不含 target / 更新时间。
  String get sourceSignature => [
    sourceWeek,
    sourceWeekday,
    sourceStartLesson,
    sourceEndLesson,
    sourceCourseName.trim(),
  ].join('|');

  ScheduleDateOverride copyWith({
    String? id,
    ScheduleTermContext? termContext,
    String? sourceDate,
    int? sourceWeek,
    int? sourceWeekday,
    int? sourceStartLesson,
    int? sourceEndLesson,
    String? sourceCourseName,
    String? sourceTeacherName,
    String? sourceClassroom,
    String? targetDate,
    int? targetWeek,
    int? targetWeekday,
    int? targetStartLesson,
    int? targetEndLesson,
    String? targetClassroom,
    String? targetTeacherName,
    DateTime? updatedAt,
  }) {
    return ScheduleDateOverride(
      id: id ?? this.id,
      termContext: termContext ?? this.termContext,
      sourceDate: sourceDate ?? this.sourceDate,
      sourceWeek: sourceWeek ?? this.sourceWeek,
      sourceWeekday: sourceWeekday ?? this.sourceWeekday,
      sourceStartLesson: sourceStartLesson ?? this.sourceStartLesson,
      sourceEndLesson: sourceEndLesson ?? this.sourceEndLesson,
      sourceCourseName: sourceCourseName ?? this.sourceCourseName,
      sourceTeacherName: sourceTeacherName ?? this.sourceTeacherName,
      sourceClassroom: sourceClassroom ?? this.sourceClassroom,
      targetDate: targetDate ?? this.targetDate,
      targetWeek: targetWeek ?? this.targetWeek,
      targetWeekday: targetWeekday ?? this.targetWeekday,
      targetStartLesson: targetStartLesson ?? this.targetStartLesson,
      targetEndLesson: targetEndLesson ?? this.targetEndLesson,
      targetClassroom: targetClassroom ?? this.targetClassroom,
      targetTeacherName: targetTeacherName ?? this.targetTeacherName,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'termContext': termContext?.toJson(),
    'sourceDate': sourceDate,
    'sourceWeek': sourceWeek,
    'sourceWeekday': sourceWeekday,
    'sourceStartLesson': sourceStartLesson,
    'sourceEndLesson': sourceEndLesson,
    'sourceCourseName': sourceCourseName,
    'sourceTeacherName': sourceTeacherName,
    'sourceClassroom': sourceClassroom,
    'targetDate': targetDate,
    'targetWeek': targetWeek,
    'targetWeekday': targetWeekday,
    'targetStartLesson': targetStartLesson,
    'targetEndLesson': targetEndLesson,
    'targetClassroom': targetClassroom,
    'targetTeacherName': targetTeacherName,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  /// 缓存反序列化：字段一律带兜底，坏行降级为空 id / 0 周次，
  /// 不抛异常以免整条快照作废（[matchesSource] / [matchesTarget] 对
  /// `week <= 0` 天然不命中）。
  factory ScheduleDateOverride.fromJson(Map<String, dynamic> json) {
    final termContextJson = json['termContext'];
    return ScheduleDateOverride(
      id: json['id']?.toString() ?? '',
      termContext: termContextJson is Map<String, dynamic>
          ? ScheduleTermContext.fromJson(termContextJson)
          : null,
      sourceDate: json['sourceDate']?.toString() ?? '',
      sourceWeek: _intFromJson(json['sourceWeek']),
      sourceWeekday: _intFromJson(json['sourceWeekday']),
      sourceStartLesson: _intFromJson(json['sourceStartLesson']),
      sourceEndLesson: _intFromJson(json['sourceEndLesson']),
      sourceCourseName: json['sourceCourseName']?.toString() ?? '',
      sourceTeacherName: json['sourceTeacherName']?.toString() ?? '',
      sourceClassroom: json['sourceClassroom']?.toString() ?? '',
      targetDate: json['targetDate']?.toString() ?? '',
      targetWeek: _intFromJson(json['targetWeek']),
      targetWeekday: _intFromJson(json['targetWeekday']),
      targetStartLesson: _intFromJson(json['targetStartLesson']),
      targetEndLesson: _intFromJson(json['targetEndLesson']),
      targetClassroom: json['targetClassroom']?.toString() ?? '',
      targetTeacherName: json['targetTeacherName']?.toString() ?? '',
      updatedAt:
          dateFromEpochMillis(json['updatedAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  static int _intFromJson(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
