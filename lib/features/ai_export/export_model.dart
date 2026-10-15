import '../../core/academic/effective_week_courses.dart';
import '../../core/academic/exam_model.dart';
import '../../core/academic/schedule_cache_snapshot.dart';
import '../../core/academic/schedule_constants.dart';
import '../../core/academic/schedule_model.dart';
import '../../core/notice/notice_model.dart';

/// 导出 JSON schema 版本；结构变化时递增。
///
/// v1 = 仅成绩的单模块文档（PR #90）；v2 = 多模块信封；
/// v3 = 顶层 `context`（给 AI 的背景说明）+ 七个模块。
const int kAiExportSchemaVersion = 3;

/// 模块依赖的登录域：决定「需登录」判定与账号切换时清空哪些数据。
enum ExportAuthDomain {
  /// 教务系统（正方）：成绩 / 学业进度 / 课表 / 考试。
  academic,

  /// 统一认证（CAS）：教务处通知 / 体测。
  unified,

  /// 微信授权的第二课堂：应用侧没有可校验的账号标识。
  session,
}

/// 可导出的模块。顺序即文档内的固定输出顺序。
enum ExportModule {
  progress('progress', '学业进度', ExportAuthDomain.academic),
  grades('grades', '成绩', ExportAuthDomain.academic),
  schedule('schedule', '课表', ExportAuthDomain.academic),
  exams('exams', '考试安排', ExportAuthDomain.academic),
  secondClassroom('secondClassroom', '第二课堂', ExportAuthDomain.session),
  notices('notices', '教务处通知', ExportAuthDomain.unified),
  physicalTest('physicalTest', '体测', ExportAuthDomain.unified);

  const ExportModule(this.key, this.label, this.domain);

  final String key;
  final String label;
  final ExportAuthDomain domain;
}

/// 用途预设：单选，决定默认勾选哪些模块。
enum ExportPreset {
  planning('学业规划', {ExportModule.progress, ExportModule.grades}),
  upcoming('近期安排', {
    ExportModule.schedule,
    ExportModule.exams,
    ExportModule.secondClassroom,
    ExportModule.notices,
  }),
  all('全部', {
    ExportModule.progress,
    ExportModule.grades,
    ExportModule.schedule,
    ExportModule.exams,
    ExportModule.secondClassroom,
    ExportModule.notices,
    ExportModule.physicalTest,
  });

  const ExportPreset(this.label, this.modules);

  final String label;
  final Set<ExportModule> modules;

  /// 模块集合恰好等于某个预设时返回它；用户手动调整后返回 `null`（自定义）。
  static ExportPreset? matching(Set<ExportModule> modules) {
    for (final preset in values) {
      if (preset.modules.length == modules.length &&
          preset.modules.containsAll(modules)) {
        return preset;
      }
    }
    return null;
  }
}

/// 模块数据状态。缺失 / 过期必须明确标出，绝不用空表伪装完整结果。
enum ExportModuleStatus {
  available('available', '已获取'),
  stale('stale', '已过期'),
  missing('missing', '未获取');

  const ExportModuleStatus(this.key, this.label);

  final String key;
  final String label;

  bool get hasData => this != missing;
}

// ── 工具 ────────────────────────────────────────────────────────────────────

String? exportOptional(String? raw) {
  final t = raw?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

String exportDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

String exportDateTime(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${exportDate(d)} ${two(d.hour)}:${two(d.minute)}';
}

// ── 模块数据基类 ─────────────────────────────────────────────────────────────

/// 单个模块的导出数据 + 元信息。所有记录类型都是白名单后的纯数据：
/// 逐字段映射，不整体序列化任何业务模型，学号 / 姓名 / 凭据从不出现。
sealed class ExportModuleData {
  const ExportModuleData({
    required this.module,
    required this.status,
    this.lastUpdatedAt,
    this.dataSource,
  });

  /// 选中却没有数据的模块占位。
  const factory ExportModuleData.missing(ExportModule module) =
      MissingModuleData;

  final ExportModule module;
  final ExportModuleStatus status;
  final DateTime? lastUpdatedAt;

  /// 数据来源（本地缓存 / 刚获取）；无法确证为 `null`。
  final String? dataSource;

  /// 条目数；未获取为 `null`（区别于「已获取但 0 条」）。
  int? get itemCount;

  String get scopeLabel;
}

final class MissingModuleData extends ExportModuleData {
  const MissingModuleData(ExportModule module)
    : super(module: module, status: ExportModuleStatus.missing);

  @override
  int? get itemCount => null;

  @override
  String get scopeLabel => '—';
}

// ── 成绩 ────────────────────────────────────────────────────────────────────

/// 白名单后的单条成绩：只保留学业字段。
class GradesExportRecord {
  const GradesExportRecord({
    required this.courseName,
    this.grade,
    this.percentageScore,
    required this.gpaPoints,
    required this.credits,
    required this.academicYear,
    required this.semester,
    this.examType,
    this.assessmentMethod,
    this.courseRequirement,
  });

  final String courseName;
  final String? grade;
  final String? percentageScore;
  final double gpaPoints;
  final double credits;
  final String academicYear;
  final String semester;

  /// 教务「考试性质」原文（正常考试 / 补考 / 重修 …，以实际出现值为准）。
  final String? examType;
  final String? assessmentMethod;

  /// 课程性质原文（必修 / 选修 …，含义以教务为准）。
  final String? courseRequirement;

  /// 等级制成绩：`grade` 非空且不是数字（优秀 / 良好 / 合格 …）。
  bool get isLetterGrade {
    final g = grade;
    return g != null && double.tryParse(g) == null;
  }

  Map<String, dynamic> toJson() => {
    'courseName': courseName,
    'grade': grade,
    'percentageScore': percentageScore,
    'gpaPoints': gpaPoints,
    'credits': credits,
    'academicYear': academicYear,
    'semester': semester,
    'examType': examType,
    'assessmentMethod': assessmentMethod,
    'courseRequirement': courseRequirement,
  };
}

/// 本应用口径的绩点汇总（与成绩页「概览」同一算法）：
/// 仅统计 `gpaPoints > 0` 的记录，学分加权平均。
class GpaSummary {
  const GpaSummary({
    required this.gpa,
    required this.countedCourses,
    required this.countedCredits,
    required this.excludedCourses,
    required this.excludedCredits,
  });

  factory GpaSummary.from(Iterable<GradesExportRecord> records) {
    var points = 0.0;
    var counted = 0.0;
    var countedCourses = 0;
    var excluded = 0.0;
    var excludedCourses = 0;
    for (final r in records) {
      if (r.gpaPoints > 0) {
        points += r.gpaPoints * r.credits;
        counted += r.credits;
        countedCourses++;
      } else {
        excluded += r.credits;
        excludedCourses++;
      }
    }
    return GpaSummary(
      gpa: counted > 0 ? points / counted : null,
      countedCourses: countedCourses,
      countedCredits: counted,
      excludedCourses: excludedCourses,
      excludedCredits: excluded,
    );
  }

  /// 没有参与计算的记录时为 `null`（不伪造 0）。
  final double? gpa;
  final int countedCourses;
  final double countedCredits;

  /// `gpaPoints == 0` 而未计入分母的记录（等级制「合格」类、挂科等）。
  final int excludedCourses;
  final double excludedCredits;

  Map<String, dynamic> toJson() => {
    'gpa': gpa == null ? null : double.parse(gpa!.toStringAsFixed(4)),
    'countedCourses': countedCourses,
    'countedCredits': countedCredits,
    'excludedCourses': excludedCourses,
    'excludedCredits': excludedCredits,
  };
}

/// 单学期汇总。
class GradesTermSummary {
  const GradesTermSummary({
    required this.academicYear,
    required this.semester,
    required this.courseCount,
    required this.credits,
    required this.summary,
  });

  final String academicYear;
  final String semester;
  final int courseCount;
  final double credits;
  final GpaSummary summary;

  String get label => '$academicYear $semester'.trim();
}

final class GradesModuleData extends ExportModuleData {
  const GradesModuleData({
    required super.status,
    super.lastUpdatedAt,
    super.dataSource,
    required this.records,
  }) : super(module: ExportModule.grades);

  final List<GradesExportRecord> records;

  double get totalCredits => records.fold(0, (sum, r) => sum + r.credits);

  GpaSummary get summary => GpaSummary.from(records);

  /// 按学年学期升序的分学期汇总。
  List<GradesTermSummary> get terms {
    final groups = <String, List<GradesExportRecord>>{};
    for (final r in records) {
      final key = '${r.academicYear}\u0000${r.semester}';
      groups.putIfAbsent(key, () => []).add(r);
    }
    int rank(String semester) => switch (semester) {
      '第一学期' => 1,
      '第二学期' => 2,
      _ => 0,
    };
    final out = [
      for (final g in groups.values)
        GradesTermSummary(
          academicYear: g.first.academicYear,
          semester: g.first.semester,
          courseCount: g.length,
          credits: g.fold(0.0, (s, r) => s + r.credits),
          summary: GpaSummary.from(g),
        ),
    ];
    out.sort((a, b) {
      final y = a.academicYear.compareTo(b.academicYear);
      return y != 0 ? y : rank(a.semester).compareTo(rank(b.semester));
    });
    return out;
  }

  @override
  int? get itemCount => status.hasData ? records.length : null;

  @override
  String get scopeLabel => '全部学期';
}

// ── 学业进度 ────────────────────────────────────────────────────────────────

/// 学业进度统计区（所有字段可缺失）。
class ProgressSummaryRecord {
  const ProgressSummaryRecord({
    this.statTime,
    this.gpa,
    this.planTotal,
    this.planPassed,
    this.planFailed,
    this.planNotTaken,
    this.studying,
    this.outsidePassed,
    this.outsideFailed,
  });

  final String? statTime;
  final String? gpa;
  final int? planTotal;
  final int? planPassed;
  final int? planFailed;
  final int? planNotTaken;
  final int? studying;
  final int? outsidePassed;
  final int? outsideFailed;

  Map<String, dynamic> toJson() => {
    'statTime': statTime,
    'gpa': gpa,
    'planTotal': planTotal,
    'planPassed': planPassed,
    'planFailed': planFailed,
    'planNotTaken': planNotTaken,
    'studying': studying,
    'outsidePassed': outsidePassed,
    'outsideFailed': outsideFailed,
  };
}

/// 学分要求树中的一门课程。
class ProgressCourseRecord {
  const ProgressCourseRecord({
    this.courseCode,
    required this.courseName,
    required this.status,
    required this.credits,
    this.nature,
    this.category,
    required this.inPlan,
    this.scoreTerm,
    this.score,
    this.gradePoint,
    this.makeupScore,
    this.retakeScore,
    this.suggestedTerm,
  });

  final String? courseCode;
  final String courseName;

  /// 修读状态中文标签（在修 / 未过 / 未修 / 已修 …）。
  final String status;
  final double credits;
  final String? nature;
  final String? category;
  final bool inPlan;
  final String? scoreTerm;
  final String? score;
  final double? gradePoint;

  /// 补考成绩 / 重修成绩（有值即发生过补考 / 重修）。
  final String? makeupScore;
  final String? retakeScore;
  final String? suggestedTerm;

  Map<String, dynamic> toJson() => {
    'courseCode': courseCode,
    'courseName': courseName,
    'status': status,
    'credits': credits,
    'nature': nature,
    'category': category,
    'inPlan': inPlan,
    'scoreTerm': scoreTerm,
    'score': score,
    'gradePoint': gradePoint,
    'makeupScore': makeupScore,
    'retakeScore': retakeScore,
    'suggestedTerm': suggestedTerm,
  };
}

/// 学分要求树节点。
class ProgressNodeRecord {
  const ProgressNodeRecord({
    required this.id,
    required this.name,
    this.requiredCredits,
    this.earnedCredits,
    this.missingCredits,
    this.requiredCount,
    this.metCount,
    required this.relation,
    required this.creditStatus,
    this.children = const [],
    this.courses = const [],
  });

  final String id;
  final String name;
  final double? requiredCredits;
  final double? earnedCredits;

  /// 要求学分 − 已获学分，最低 0；无学分要求时为 `null`。
  final double? missingCredits;
  final int? requiredCount;
  final int? metCount;

  /// 子节点之间的关系（并且 / 或者 …）。
  final String relation;

  /// `notMet` / `met` / `exceeded` / `none`。
  final String creditStatus;
  final List<ProgressNodeRecord> children;
  final List<ProgressCourseRecord> courses;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'requiredCredits': requiredCredits,
    'earnedCredits': earnedCredits,
    'missingCredits': missingCredits,
    'requiredCount': requiredCount,
    'metCount': metCount,
    'relation': relation,
    'creditStatus': creditStatus,
    'children': [for (final c in children) c.toJson()],
    'courses': [for (final c in courses) c.toJson()],
  };
}

const String _pathSep = ' / ';

final class ProgressModuleData extends ExportModuleData {
  const ProgressModuleData({
    required super.status,
    super.lastUpdatedAt,
    super.dataSource,
    this.summary,
    this.nodes = const [],
  }) : super(module: ExportModule.progress);

  final ProgressSummaryRecord? summary;
  final List<ProgressNodeRecord> nodes;

  /// 展平后的 (所属路径, 课程)，保持树的先序。
  List<(String, ProgressCourseRecord)> get flatCourses {
    final out = <(String, ProgressCourseRecord)>[];
    void walk(ProgressNodeRecord n, List<String> path) {
      final here = [...path, n.name];
      for (final c in n.courses) {
        out.add((here.join(_pathSep), c));
      }
      for (final child in n.children) {
        walk(child, here);
      }
    }

    for (final n in nodes) {
      walk(n, const []);
    }
    return out;
  }

  /// 展平后的 (路径, 节点)，先序。
  List<(String, ProgressNodeRecord)> get flatNodes {
    final out = <(String, ProgressNodeRecord)>[];
    void walk(ProgressNodeRecord n, List<String> path) {
      final here = [...path, n.name];
      out.add((here.join(_pathSep), n));
      for (final child in n.children) {
        walk(child, here);
      }
    }

    for (final n in nodes) {
      walk(n, const []);
    }
    return out;
  }

  @override
  int? get itemCount => status.hasData ? flatCourses.length : null;

  @override
  String get scopeLabel => '培养方案';
}

// ── 课表 ────────────────────────────────────────────────────────────────────

/// 单个上课安排（周课表中的一格）。
class ScheduleCourseRecord {
  const ScheduleCourseRecord({
    required this.courseName,
    this.teacher,
    required this.weekday,
    required this.startLesson,
    required this.endLesson,
    required this.startTime,
    required this.endTime,
    this.weekRange,
    this.location,
    this.campus,
    this.courseType,
    required this.hasScheduleChange,
  });

  factory ScheduleCourseRecord.fromEntry(CourseEntry c) {
    final type = exportOptional(c.typeSymbol);
    return ScheduleCourseRecord(
      courseName: c.courseName.trim(),
      teacher: exportOptional(c.teacherName),
      weekday: c.weekday,
      startLesson: c.startLesson,
      endLesson: c.endLesson,
      startTime: ScheduleSlotTimes.startTime(c.startLesson),
      endTime: ScheduleSlotTimes.endTime(c.endLesson),
      weekRange: exportOptional(c.weekRange),
      location: exportOptional(c.classroom),
      campus: exportOptional(c.campus),
      courseType: type == null ? null : scheduleCourseTypeLabel(type),
      hasScheduleChange: c.hasScheduleChange,
    );
  }

  final String courseName;
  final String? teacher;

  /// 1 = 周一 … 7 = 周日。
  final int weekday;
  final int startLesson;
  final int endLesson;
  final String startTime;
  final String endTime;
  final String? weekRange;
  final String? location;
  final String? campus;
  final String? courseType;

  /// 教务标记该教学班有调课记录。
  final bool hasScheduleChange;

  Map<String, dynamic> toJson() => {
    'courseName': courseName,
    'teacher': teacher,
    'weekday': weekday,
    'startLesson': startLesson,
    'endLesson': endLesson,
    'startTime': startTime,
    'endTime': endTime,
    'weekRange': weekRange,
    'location': location,
    'campus': campus,
    'courseType': courseType,
    'hasScheduleChange': hasScheduleChange,
  };
}

/// 某教学周「已应用调课」后的有效课表。
class ScheduleWeekRecord {
  const ScheduleWeekRecord({required this.week, required this.courses});

  final int week;
  final List<ScheduleCourseRecord> courses;

  Map<String, dynamic> toJson() => {
    'week': week,
    'courses': [for (final c in courses) c.toJson()],
  };
}

final class ScheduleModuleData extends ExportModuleData {
  const ScheduleModuleData({
    required super.status,
    super.lastUpdatedAt,
    super.dataSource,
    required this.termLabel,
    required this.academicYear,
    required this.termCode,
    required this.courses,
    required this.weeks,
    required this.changeRuleCount,
  }) : super(module: ExportModule.schedule);

  /// 以课表缓存快照构建。[currentWeek] 为当前教学周（1-20）；
  /// 未开学只给第 1 周，已超出教学周范围则不给有效周课表。
  factory ScheduleModuleData.fromSnapshot(
    ScheduleCacheSnapshot snapshot, {
    required DateTime now,
    required int currentWeek,
    required bool beforeSemesterStart,
    required bool afterSemesterEnd,
    String? dataSource,
  }) {
    int byTime(ScheduleCourseRecord a, ScheduleCourseRecord b) {
      final d = a.weekday.compareTo(b.weekday);
      return d != 0 ? d : a.startLesson.compareTo(b.startLesson);
    }

    final base = [
      for (final c in snapshot.courses) ScheduleCourseRecord.fromEntry(c),
    ]..sort(byTime);
    final weekNumbers = afterSemesterEnd
        ? const <int>[]
        : beforeSemesterStart
        ? const [1]
        : [currentWeek, if (currentWeek < scheduleWeekCount) currentWeek + 1];
    final weeks = [
      for (final w in weekNumbers)
        ScheduleWeekRecord(
          week: w,
          courses: [
            for (final c in buildEffectiveWeekCourses(
              courses: snapshot.courses,
              week: w,
              changeRules: snapshot.changeRules,
              termContext: snapshot.termContext,
            ))
              ScheduleCourseRecord.fromEntry(c),
          ]..sort(byTime),
        ),
    ];
    final term = snapshot.termContext;
    return ScheduleModuleData(
      status: snapshot.needsScheduleRefresh(now)
          ? ExportModuleStatus.stale
          : ExportModuleStatus.available,
      lastUpdatedAt: snapshot.lastUpdatedAt,
      dataSource: dataSource,
      termLabel:
          '${term.academicYear}-${term.academicYear + 1} 学年${term.termLabel}',
      academicYear: term.academicYear,
      termCode: term.term,
      courses: base,
      weeks: weeks,
      changeRuleCount: snapshot.changeRules.length,
    );
  }

  final String termLabel;
  final int academicYear;

  /// 正方学期代码：3 = 第一学期，12 = 第二学期。
  final int termCode;

  /// 该学期的周课表底稿（按 `weekRange` 在对应周出现，**未**应用调课通知）。
  final List<ScheduleCourseRecord> courses;

  /// 当前周（与下一周）已应用调课通知后的有效课表。
  final List<ScheduleWeekRecord> weeks;
  final int changeRuleCount;

  @override
  int? get itemCount => status.hasData ? courses.length : null;

  @override
  String get scopeLabel => termLabel;
}

// ── 考试 ────────────────────────────────────────────────────────────────────

/// 白名单后的单场考试：逐字段映射，不整体序列化 [ExamEntry]。
class ExamExportRecord {
  const ExamExportRecord({
    required this.courseName,
    this.courseCode,
    this.examName,
    this.date,
    this.startTime,
    this.endTime,
    this.timeText,
    this.weekNumber,
    this.weekday,
    this.location,
    this.campus,
    this.seatNumber,
    this.department,
    required this.isRetake,
    this.academicYear,
    this.semester,
  });

  factory ExamExportRecord.fromEntry(ExamEntry e) => ExamExportRecord(
    courseName: e.courseName.trim(),
    courseCode: exportOptional(e.courseCode),
    examName: exportOptional(e.examName),
    date: e.examDate == null ? null : exportDate(e.examDate!),
    startTime: exportOptional(e.startTime),
    endTime: exportOptional(e.endTime),
    timeText: exportOptional(e.examTimeRaw),
    weekNumber: e.weekNumber > 0 ? e.weekNumber : null,
    weekday: e.weekday >= 1 && e.weekday <= 7 ? e.weekday : null,
    location: exportOptional(e.location),
    campus: exportOptional(e.campus),
    seatNumber: exportOptional(e.seatNumber),
    department: exportOptional(e.department),
    isRetake: e.isRetake,
    academicYear: exportOptional(e.academicYear),
    semester: exportOptional(e.semester),
  );

  final String courseName;
  final String? courseCode;
  final String? examName;

  /// `yyyy-MM-dd`；时间待定为 `null`。
  final String? date;
  final String? startTime;
  final String? endTime;

  /// 教务原始时间文案；解析失败时仍可保留原文。
  final String? timeText;
  final int? weekNumber;

  /// 1 = 周一 … 7 = 周日；未知为 `null`。
  final int? weekday;
  final String? location;
  final String? campus;
  final String? seatNumber;
  final String? department;
  final bool isRetake;
  final String? academicYear;
  final String? semester;

  Map<String, dynamic> toJson() => {
    'courseName': courseName,
    'courseCode': courseCode,
    'examName': examName,
    'date': date,
    'startTime': startTime,
    'endTime': endTime,
    'timeText': timeText,
    'weekNumber': weekNumber,
    'weekday': weekday,
    'location': location,
    'campus': campus,
    'seatNumber': seatNumber,
    'department': department,
    'isRetake': isRetake,
    'academicYear': academicYear,
    'semester': semester,
  };
}

final class ExamsModuleData extends ExportModuleData {
  const ExamsModuleData({
    required super.status,
    super.lastUpdatedAt,
    super.dataSource,
    required this.records,
  }) : super(module: ExportModule.exams);

  factory ExamsModuleData.fromEntries(
    List<ExamEntry> exams, {
    required ExportModuleStatus status,
    DateTime? lastUpdatedAt,
    String? dataSource,
  }) => ExamsModuleData(
    status: status,
    lastUpdatedAt: lastUpdatedAt,
    dataSource: dataSource,
    records: [for (final e in exams) ExamExportRecord.fromEntry(e)],
  );

  final List<ExamExportRecord> records;

  @override
  int? get itemCount => status.hasData ? records.length : null;

  /// 考试接口按当前学期查询，缓存里有什么导出什么。
  @override
  String get scopeLabel => '当前学期';
}

// ── 第二课堂 ────────────────────────────────────────────────────────────────

/// 一项已报名的第二课堂活动。
///
/// **「已报名」「已签到」与「已认定学时」是三件事**：应用只知道前两者
/// （活动列表里的报名 / 签到标记），学时认定结果无从获知，因此 [creditHours]
/// 只是活动**标称**学时，不代表已计入。
class SecondClassroomExportRecord {
  const SecondClassroomExportRecord({
    required this.title,
    this.category,
    this.organizer,
    this.activityStart,
    this.activityEnd,
    this.location,
    required this.creditHours,
    required this.checkedIn,
  });

  final String title;
  final String? category;
  final String? organizer;
  final DateTime? activityStart;
  final DateTime? activityEnd;
  final String? location;

  /// 活动标称学时（不是已认定学时）。
  final double creditHours;
  final bool checkedIn;

  Map<String, dynamic> toJson() => {
    'title': title,
    'category': category,
    'organizer': organizer,
    'activityStart': activityStart?.toIso8601String(),
    'activityEnd': activityEnd?.toIso8601String(),
    'location': location,
    'nominalCreditHours': creditHours,
    'checkedIn': checkedIn,
  };
}

final class SecondClassroomModuleData extends ExportModuleData {
  const SecondClassroomModuleData({
    required super.status,
    super.lastUpdatedAt,
    super.dataSource,
    required this.enrolled,
  }) : super(module: ExportModule.secondClassroom);

  /// 已报名的活动（按活动开始时间升序，缺失沉底）。
  final List<SecondClassroomExportRecord> enrolled;

  int get checkedInCount => enrolled.where((r) => r.checkedIn).length;

  /// 已签到活动的标称学时合计——**不是**学校认定的学时。
  double get checkedInNominalHours => enrolled
      .where((r) => r.checkedIn)
      .fold(0.0, (sum, r) => sum + r.creditHours);

  @override
  int? get itemCount => status.hasData ? enrolled.length : null;

  @override
  String get scopeLabel => '未结束活动中已报名的';
}

// ── 教务处通知 ──────────────────────────────────────────────────────────────

/// 通知只导出元数据，**不含正文**。
class NoticeExportRecord {
  const NoticeExportRecord({
    required this.title,
    this.date,
    this.category,
    required this.url,
  });

  factory NoticeExportRecord.fromNotice(Notice n) => NoticeExportRecord(
    title: n.title.trim(),
    date: exportOptional(n.date),
    category: exportOptional(n.category),
    url: n.url.trim(),
  );

  final String title;
  final String? date;
  final String? category;
  final String url;

  Map<String, dynamic> toJson() => {
    'title': title,
    'date': date,
    'category': category,
    'url': url,
  };
}

/// 通知窗口：导出时间前 30 天。
const int kNoticeWindowDays = 30;

final class NoticesModuleData extends ExportModuleData {
  const NoticesModuleData({
    required super.status,
    super.lastUpdatedAt,
    super.dataSource,
    required this.records,
  }) : super(module: ExportModule.notices);

  /// 仅保留 [exportedAt] 前 [kNoticeWindowDays] 天内的通知（新 → 旧）；
  /// 日期缺失 / 无法解析的通知无法判定是否在窗口内，一律不导出。
  factory NoticesModuleData.fromNotices(
    Iterable<Notice> notices, {
    required DateTime exportedAt,
    required ExportModuleStatus status,
    DateTime? lastUpdatedAt,
    String? dataSource,
  }) {
    final today = DateTime(exportedAt.year, exportedAt.month, exportedAt.day);
    final cutoff = today.subtract(const Duration(days: kNoticeWindowDays));
    final windowed = Notice.sortByDateDescStable(
      notices.where((n) {
        final d = n.parsedDate;
        return d != null && !d.isBefore(cutoff);
      }),
    );
    return NoticesModuleData(
      status: status,
      lastUpdatedAt: lastUpdatedAt,
      dataSource: dataSource,
      records: [for (final n in windowed) NoticeExportRecord.fromNotice(n)],
    );
  }

  final List<NoticeExportRecord> records;

  @override
  int? get itemCount => status.hasData ? records.length : null;

  @override
  String get scopeLabel => '近 $kNoticeWindowDays 天';
}

// ── 体测 ────────────────────────────────────────────────────────────────────

class PhysicalTestItemRecord {
  const PhysicalTestItemRecord({
    required this.name,
    this.result,
    this.score,
    this.level,
  });

  final String name;
  final String? result;
  final String? score;
  final String? level;

  Map<String, dynamic> toJson() => {
    'name': name,
    'result': result,
    'score': score,
    'level': level,
  };
}

class PhysicalTestYearRecord {
  const PhysicalTestYearRecord({
    required this.academicYear,
    this.totalScore,
    this.grade,
    this.items = const [],
  });

  final String academicYear;
  final String? totalScore;
  final String? grade;
  final List<PhysicalTestItemRecord> items;

  Map<String, dynamic> toJson() => {
    'academicYear': academicYear,
    'totalScore': totalScore,
    'grade': grade,
    'items': [for (final i in items) i.toJson()],
  };
}

final class PhysicalTestModuleData extends ExportModuleData {
  const PhysicalTestModuleData({
    required super.status,
    super.lastUpdatedAt,
    super.dataSource,
    required this.records,
  }) : super(module: ExportModule.physicalTest);

  final List<PhysicalTestYearRecord> records;

  @override
  int? get itemCount => status.hasData ? records.length : null;

  @override
  String get scopeLabel => '历年';
}
