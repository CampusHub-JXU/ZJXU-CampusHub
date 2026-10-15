import 'dart:convert';

import '../../../core/academic/exam_model.dart';
import '../grades_model.dart';
import '../progress/academic_progress_model.dart';
import 'grades_export_serializer.dart';

/// 学业数据导出的 JSON schema 版本；结构变化时递增。
///
/// v1 = 仅成绩的单模块文档（PR #90）；v2 = 多模块信封
/// （`modules.<key>` 各带 `status` / `lastUpdatedAt` / `dataSource`）。
const int kAcademicExportSchemaVersion = 2;

const String _disclaimer =
    '本文件由本机已加载 / 缓存的数据整理生成，导出时不会重新联网获取，'
    '也不代表学校官方学业审核结果；成绩、绩点与学分以教务系统为准。';

const String _privacyNote = '默认不含学号、姓名、账号凭据、Cookie 或支付信息。';

/// 可导出的模块（首版：成绩 / 考试安排 / 学业进度）。
enum ExportModule {
  grades('grades', '成绩'),
  exams('exams', '考试安排'),
  progress('progress', '学业进度');

  const ExportModule(this.key, this.label);

  final String key;
  final String label;
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

// ── 输入（调用方在打开弹层时冻结） ─────────────────────────────────────────

/// 已缓存的考试安排及其新鲜度。
class ExamExportData {
  const ExamExportData({
    required this.exams,
    this.updatedAt,
    this.isStale = false,
  });

  final List<ExamEntry> exams;
  final DateTime? updatedAt;
  final bool isStale;
}

/// 已缓存的学业进度报告及其新鲜度。
class ProgressExportData {
  const ProgressExportData({
    required this.report,
    this.updatedAt,
    this.isStale = false,
  });

  final AcademicProgressReport report;
  final DateTime? updatedAt;
  final bool isStale;
}

/// 一次导出可用的全部已加载数据；`null` / 空即「未获取」。
///
/// 只持有纯数据模型，不碰网络与认证。归属校验（owner / revision）由
/// 调用方（捕获函数与弹层）负责。
class AcademicExportInput {
  const AcademicExportInput({
    required this.exportedAt,
    this.allGrades = const [],
    this.termGrades,
    this.termScope,
    this.gradesUpdatedAt,
    this.gradesStale = false,
    this.gradesSource,
    this.exams,
    this.progress,
  });

  final DateTime exportedAt;

  /// 成绩页已加载的全部学期成绩。
  final List<GradeEntry> allGrades;

  /// 当前选中学期的成绩子集；未选学期（全部）时为 `null`。
  final List<GradeEntry>? termGrades;
  final GradesExportScope? termScope;

  final DateTime? gradesUpdatedAt;
  final bool gradesStale;

  /// 页面无法确证来自缓存还是本次读取时为 `null`，如实显示「未知」。
  final String? gradesSource;

  final ExamExportData? exams;
  final ProgressExportData? progress;

  bool get hasTermScope => termGrades != null && termScope != null;

  /// 构建所选模块的导出文档。[gradesAllTerms] 仅影响成绩模块。
  AcademicExportDocument build({
    required Set<ExportModule> modules,
    bool gradesAllTerms = false,
  }) {
    return AcademicExportDocument(
      exportedAt: exportedAt,
      modules: [
        for (final m in ExportModule.values)
          if (modules.contains(m))
            switch (m) {
              ExportModule.grades => _buildGrades(gradesAllTerms),
              ExportModule.exams => _buildExams(),
              ExportModule.progress => _buildProgress(),
            },
      ],
    );
  }

  GradesModuleData _buildGrades(bool allTerms) {
    final useTerm = !allTerms && hasTermScope;
    final source = useTerm ? termGrades! : allGrades;
    if (source.isEmpty) return const GradesModuleData.missing();
    return GradesModuleData(
      status: gradesStale
          ? ExportModuleStatus.stale
          : ExportModuleStatus.available,
      lastUpdatedAt: gradesUpdatedAt,
      dataSource: gradesSource,
      scope: useTerm ? termScope! : const GradesExportScope(label: '全部已加载学期'),
      records: [for (final g in source) GradesExportRecord.fromEntry(g)],
    );
  }

  ExamsModuleData _buildExams() {
    final data = exams;
    if (data == null) return const ExamsModuleData.missing();
    return ExamsModuleData(
      status: data.isStale
          ? ExportModuleStatus.stale
          : ExportModuleStatus.available,
      lastUpdatedAt: data.updatedAt,
      dataSource: '本地缓存',
      records: [for (final e in data.exams) ExamExportRecord.fromEntry(e)],
    );
  }

  ProgressModuleData _buildProgress() {
    final data = progress;
    if (data == null) return const ProgressModuleData.missing();
    return ProgressModuleData(
      status: data.isStale
          ? ExportModuleStatus.stale
          : ExportModuleStatus.available,
      lastUpdatedAt: data.updatedAt,
      dataSource: '本地缓存',
      summary: ProgressSummaryRecord.fromSummary(data.report.summary),
      nodes: [
        for (final r in data.report.roots) ProgressNodeRecord.fromNode(r),
      ],
    );
  }
}

// ── 白名单记录 ──────────────────────────────────────────────────────────────

String? _opt(String? raw) {
  final t = raw?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

String _fmtDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

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

  factory ExamExportRecord.fromEntry(ExamEntry e) => ExamExportRecord(
    courseName: e.courseName.trim(),
    courseCode: _opt(e.courseCode),
    examName: _opt(e.examName),
    date: e.examDate == null ? null : _fmtDate(e.examDate!),
    startTime: _opt(e.startTime),
    endTime: _opt(e.endTime),
    timeText: _opt(e.examTimeRaw),
    weekNumber: e.weekNumber > 0 ? e.weekNumber : null,
    weekday: e.weekday >= 1 && e.weekday <= 7 ? e.weekday : null,
    location: _opt(e.location),
    campus: _opt(e.campus),
    seatNumber: _opt(e.seatNumber),
    department: _opt(e.department),
    isRetake: e.isRetake,
    academicYear: _opt(e.academicYear),
    semester: _opt(e.semester),
  );

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

  factory ProgressSummaryRecord.fromSummary(AcademicProgressSummary s) =>
      ProgressSummaryRecord(
        statTime: _opt(s.statTime),
        gpa: _opt(s.gpa),
        planTotal: s.planTotal,
        planPassed: s.planPassed,
        planFailed: s.planFailed,
        planNotTaken: s.planNotTaken,
        studying: s.studying,
        outsidePassed: s.outsidePassed,
        outsideFailed: s.outsideFailed,
      );

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
  final String? suggestedTerm;

  factory ProgressCourseRecord.fromCourse(AcademicProgressCourse c) =>
      ProgressCourseRecord(
        courseCode: _opt(c.courseCode),
        courseName: c.courseName.trim(),
        status: c.status.label,
        credits: c.credits,
        nature: _opt(c.nature),
        category: _opt(c.category),
        inPlan: c.inPlan,
        scoreTerm: _opt(c.scoreTerm),
        score: _opt(c.displayScore),
        gradePoint: c.gradePoint,
        suggestedTerm: _opt(c.suggestedTerm),
      );

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
  final double? missingCredits;
  final int? requiredCount;
  final int? metCount;
  final String relation;

  /// `notMet` / `met` / `exceeded` / `none`。
  final String creditStatus;
  final List<ProgressNodeRecord> children;
  final List<ProgressCourseRecord> courses;

  factory ProgressNodeRecord.fromNode(RequirementNode n) => ProgressNodeRecord(
    id: n.id,
    name: n.name.trim(),
    requiredCredits: n.requiredCredits,
    earnedCredits: n.earnedCredits,
    missingCredits: n.missingCredits,
    requiredCount: n.requiredCount,
    metCount: n.metCount,
    relation: n.relation.label,
    creditStatus: n.creditStatus.name,
    children: [for (final c in n.children) ProgressNodeRecord.fromNode(c)],
    courses: [for (final c in n.courses) ProgressCourseRecord.fromCourse(c)],
  );

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

// ── 文档 ────────────────────────────────────────────────────────────────────

/// 单个模块的导出数据 + 元信息。
sealed class ExportModuleData {
  const ExportModuleData({
    required this.module,
    required this.status,
    this.lastUpdatedAt,
    this.dataSource,
  });

  final ExportModule module;
  final ExportModuleStatus status;
  final DateTime? lastUpdatedAt;

  /// 数据来源（缓存 / 本次读取）；无法确证为 `null`。
  final String? dataSource;

  /// 条目数；未获取为 `null`（区别于「已获取但 0 条」）。
  int? get itemCount;

  String get scopeLabel;
}

final class GradesModuleData extends ExportModuleData {
  const GradesModuleData({
    required super.status,
    super.lastUpdatedAt,
    super.dataSource,
    required this.scope,
    required this.records,
  }) : super(module: ExportModule.grades);

  const GradesModuleData.missing()
    : scope = const GradesExportScope(label: '\u2014'),
      records = const [],
      super(module: ExportModule.grades, status: ExportModuleStatus.missing);

  final GradesExportScope scope;
  final List<GradesExportRecord> records;

  double get totalCredits => records.fold(0, (sum, r) => sum + r.credits);

  @override
  int? get itemCount => status.hasData ? records.length : null;

  @override
  String get scopeLabel => scope.label;
}

final class ExamsModuleData extends ExportModuleData {
  const ExamsModuleData({
    required super.status,
    super.lastUpdatedAt,
    super.dataSource,
    required this.records,
  }) : super(module: ExportModule.exams);

  const ExamsModuleData.missing()
    : records = const [],
      super(module: ExportModule.exams, status: ExportModuleStatus.missing);

  final List<ExamExportRecord> records;

  @override
  int? get itemCount => status.hasData ? records.length : null;

  /// 考试接口不分学期，缓存里有什么导出什么。
  @override
  String get scopeLabel => '全部已获取';
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

  const ProgressModuleData.missing()
    : summary = null,
      nodes = const [],
      super(module: ExportModule.progress, status: ExportModuleStatus.missing);

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

/// 一次导出的完整文档：所选模块（按固定顺序）+ 导出时间。
class AcademicExportDocument {
  const AcademicExportDocument({
    required this.exportedAt,
    required this.modules,
  });

  final DateTime exportedAt;
  final List<ExportModuleData> modules;

  bool get hasAnyData => modules.any((m) => m.status.hasData);
}

// ── 序列化 ──────────────────────────────────────────────────────────────────

typedef _S = GradesExportSerializer;

/// 纯函数序列化：Markdown（默认）/ 版本化 JSON / 逐模块 CSV。
abstract final class AcademicExportBuilder {
  static String encode(GradesExportFormat format, AcademicExportDocument doc) {
    return switch (format) {
      GradesExportFormat.markdown => markdown(doc),
      GradesExportFormat.json => jsonString(doc),
      GradesExportFormat.csv => csv(doc),
    };
  }

  // ── Markdown ──────────────────────────────────────────────────────────────

  static String markdown(AcademicExportDocument doc) {
    final b = StringBuffer()
      ..writeln('# 学业数据导出')
      ..writeln()
      ..writeln('> $_disclaimer')
      ..writeln('>')
      ..writeln('> $_privacyNote')
      ..writeln('> 导出时间：${_S.formatDateTime(doc.exportedAt)}')
      ..writeln()
      ..writeln('## 数据状态')
      ..writeln()
      ..writeln('| 模块 | 状态 | 条目数 | 范围 | 最后更新 | 数据来源 |')
      ..writeln('| --- | --- | --- | --- | --- | --- |');
    for (final m in doc.modules) {
      final has = m.status.hasData;
      b.writeln(
        '| ${m.module.label} '
        '| ${m.status.label} '
        '| ${m.itemCount ?? _dash} '
        '| ${has ? _S.mdCell(m.scopeLabel) : _dash} '
        '| ${has ? _S.formatDateTime(m.lastUpdatedAt) : _dash} '
        '| ${has ? _S.mdCell(m.dataSource ?? '未知') : _dash} |',
      );
    }
    for (final m in doc.modules) {
      b
        ..writeln()
        ..writeln('## ${m.module.label}')
        ..writeln();
      if (!m.status.hasData) {
        b.writeln('> 未获取：本机暂无该模块已加载的数据，未导出，也未推测。');
        continue;
      }
      if (m.status == ExportModuleStatus.stale) {
        b
          ..writeln('> 已过期：缓存超过有效期，可能不是最新数据。')
          ..writeln();
      }
      switch (m) {
        case GradesModuleData():
          _gradesMd(b, m);
        case ExamsModuleData():
          _examsMd(b, m);
        case ProgressModuleData():
          _progressMd(b, m);
      }
    }
    return b.toString().trimRight();
  }

  static const String _dash = '\u2014';

  static void _gradesMd(StringBuffer b, GradesModuleData m) {
    b
      ..writeln('学分合计：${_S.formatCredits(m.totalCredits)}')
      ..writeln()
      ..writeln('| 课程 | 成绩 | 百分制 | 绩点 | 学分 | 学年 | 学期 | 考试性质 | 考核方式 | 课程性质 |')
      ..writeln(
        '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |',
      );
    for (final r in m.records) {
      b.writeln(
        '| ${_S.mdCell(r.courseName)} '
        '| ${_S.mdCell(r.grade)} '
        '| ${_S.mdCell(r.percentageScore)} '
        '| ${_S.formatPoints(r.gpaPoints)} '
        '| ${_S.formatCredits(r.credits)} '
        '| ${_S.mdCell(r.academicYear)} '
        '| ${_S.mdCell(r.semester)} '
        '| ${_S.mdCell(r.examType)} '
        '| ${_S.mdCell(r.assessmentMethod)} '
        '| ${_S.mdCell(r.courseRequirement)} |',
      );
    }
  }

  static void _examsMd(StringBuffer b, ExamsModuleData m) {
    if (m.records.isEmpty) {
      b.writeln('来源返回 0 条考试安排。');
      return;
    }
    b
      ..writeln('| 课程 | 课程号 | 考试名称 | 日期 | 时间 | 地点 | 校区 | 座位号 | 重修 | 学年 | 学期 |')
      ..writeln(
        '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |',
      );
    for (final r in m.records) {
      final time = (r.startTime != null && r.endTime != null)
          ? '${r.startTime}-${r.endTime}'
          : null;
      b.writeln(
        '| ${_S.mdCell(r.courseName)} '
        '| ${_S.mdCell(r.courseCode)} '
        '| ${_S.mdCell(r.examName)} '
        '| ${r.date ?? '时间待定'} '
        '| ${_S.mdCell(time)} '
        '| ${_S.mdCell(r.location)} '
        '| ${_S.mdCell(r.campus)} '
        '| ${_S.mdCell(r.seatNumber)} '
        '| ${r.isRetake ? '是' : '否'} '
        '| ${_S.mdCell(r.academicYear)} '
        '| ${_S.mdCell(r.semester)} |',
      );
    }
  }

  static void _progressMd(StringBuffer b, ProgressModuleData m) {
    final s = m.summary;
    if (s != null) {
      b
        ..writeln('### 统计')
        ..writeln()
        ..writeln('- 统计时间：${_S.mdCell(s.statTime)}')
        ..writeln('- 绩点：${_S.mdCell(s.gpa)}')
        ..writeln(
          '- 计划内课程：${_n(s.planTotal)}（通过 ${_n(s.planPassed)}，未过 '
          '${_n(s.planFailed)}，未修 ${_n(s.planNotTaken)}，在修 ${_n(s.studying)}）',
        )
        ..writeln('- 计划外：通过 ${_n(s.outsidePassed)}，未过 ${_n(s.outsideFailed)}')
        ..writeln();
    }
    b
      ..writeln('### 学分要求')
      ..writeln()
      ..writeln('| 节点 | 要求学分 | 已获学分 | 缺口 | 门次（满足/要求） | 状态 |')
      ..writeln('| --- | --- | --- | --- | --- | --- |');
    for (final (path, n) in m.flatNodes) {
      final count = (n.requiredCount == null && n.metCount == null)
          ? _dash
          : '${_n(n.metCount)}/${_n(n.requiredCount)}';
      b.writeln(
        '| ${_S.mdCell(path)} '
        '| ${_cr(n.requiredCredits)} '
        '| ${_cr(n.earnedCredits)} '
        '| ${_cr(n.missingCredits)} '
        '| $count '
        '| ${_creditStatusLabel(n.creditStatus)} |',
      );
    }
    b
      ..writeln()
      ..writeln('### 课程明细')
      ..writeln();
    final courses = m.flatCourses;
    if (courses.isEmpty) {
      b.writeln('来源未包含课程明细。');
      return;
    }
    b
      ..writeln(
        '| 所属节点 | 课程号 | 课程 | 修读状态 | 学分 | 性质 | 类别 | 计划内 '
        '| 成绩学期 | 成绩 | 绩点 | 建议修读学期 |',
      )
      ..writeln(
        '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |',
      );
    for (final (path, c) in courses) {
      b.writeln(
        '| ${_S.mdCell(path)} '
        '| ${_S.mdCell(c.courseCode)} '
        '| ${_S.mdCell(c.courseName)} '
        '| ${c.status} '
        '| ${_S.formatCredits(c.credits)} '
        '| ${_S.mdCell(c.nature)} '
        '| ${_S.mdCell(c.category)} '
        '| ${c.inPlan ? '是' : '否'} '
        '| ${_S.mdCell(c.scoreTerm)} '
        '| ${_S.mdCell(c.score)} '
        '| ${c.gradePoint == null ? _dash : _S.formatPoints(c.gradePoint!)} '
        '| ${_S.mdCell(c.suggestedTerm)} |',
      );
    }
  }

  static String _n(int? v) => v?.toString() ?? _dash;

  static String _cr(double? v) => v == null ? _dash : _S.formatCredits(v);

  static String _creditStatusLabel(String name) => switch (name) {
    'notMet' => '未满足',
    'met' => '已满足',
    'exceeded' => '已超出',
    _ => _dash,
  };

  // ── JSON ──────────────────────────────────────────────────────────────────

  /// 稳定结构：顶层键固定；每个所选模块都输出同一组元键，
  /// 未获取时数据键为 `null`（不用空数组伪装）。
  static String jsonString(AcademicExportDocument doc) {
    final payload = <String, dynamic>{
      'schemaVersion': kAcademicExportSchemaVersion,
      'exportedAt': doc.exportedAt.toUtc().toIso8601String(),
      'disclaimer': _disclaimer,
      'privacy': {'includesIdentity': false},
      'modules': {for (final m in doc.modules) m.module.key: _moduleJson(m)},
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  static Map<String, dynamic> _moduleJson(ExportModuleData m) {
    final meta = <String, dynamic>{
      'status': m.status.key,
      'lastUpdatedAt': m.lastUpdatedAt?.toUtc().toIso8601String(),
      'dataSource': m.dataSource,
      'itemCount': m.itemCount,
    };
    switch (m) {
      case GradesModuleData():
        return {
          ...meta,
          'scope': {
            'label': m.status.hasData ? m.scope.label : null,
            'academicYear': m.scope.academicYear,
            'semester': m.scope.semester,
          },
          'totalCredits': m.status.hasData ? m.totalCredits : null,
          'records': m.status.hasData
              ? [for (final r in m.records) r.toJson()]
              : null,
        };
      case ExamsModuleData():
        return {
          ...meta,
          'records': m.status.hasData
              ? [for (final r in m.records) r.toJson()]
              : null,
        };
      case ProgressModuleData():
        return {
          ...meta,
          'summary': m.summary?.toJson(),
          'requirements': m.status.hasData
              ? [for (final n in m.nodes) n.toJson()]
              : null,
        };
    }
  }

  // ── CSV ───────────────────────────────────────────────────────────────────

  /// 逐模块 CSV：取文档中第一个有数据的模块（UI 在 CSV 模式下限制单选），
  /// 不同模块不会混进同一张表。
  static String csv(AcademicExportDocument doc) {
    if (doc.modules.isEmpty) return _S.csvBom;
    final m = doc.modules.firstWhere(
      (m) => m.status.hasData,
      orElse: () => doc.modules.first,
    );
    return csvFor(m);
  }

  /// Excel 兼容（UTF-8 BOM）；未获取的模块只输出表头，不伪造行。
  static String csvFor(ExportModuleData m) {
    final b = StringBuffer()..write(_S.csvBom);
    void row(Iterable<String> cells) => b.writeln(cells.join(','));
    String t(String? v) => _S.csvField(v);
    String n(String v) => _S.csvNumberField(v);

    switch (m) {
      case GradesModuleData():
        row(
          [
            '课程',
            '成绩',
            '百分制',
            '绩点',
            '学分',
            '学年',
            '学期',
            '考试性质',
            '考核方式',
            '课程性质',
          ].map(t),
        );
        for (final r in m.records) {
          row([
            t(r.courseName),
            t(r.grade),
            t(r.percentageScore),
            n(_S.formatPoints(r.gpaPoints)),
            n(_S.formatCredits(r.credits)),
            t(r.academicYear),
            t(r.semester),
            t(r.examType),
            t(r.assessmentMethod),
            t(r.courseRequirement),
          ]);
        }
      case ExamsModuleData():
        row(
          [
            '课程',
            '课程号',
            '考试名称',
            '日期',
            '开始时间',
            '结束时间',
            '周次',
            '星期',
            '地点',
            '校区',
            '座位号',
            '开课学院',
            '重修',
            '学年',
            '学期',
          ].map(t),
        );
        for (final r in m.records) {
          row([
            t(r.courseName),
            t(r.courseCode),
            t(r.examName),
            t(r.date),
            t(r.startTime),
            t(r.endTime),
            r.weekNumber == null ? '' : n('${r.weekNumber}'),
            r.weekday == null ? '' : n('${r.weekday}'),
            t(r.location),
            t(r.campus),
            t(r.seatNumber),
            t(r.department),
            r.isRetake ? '是' : '否',
            t(r.academicYear),
            t(r.semester),
          ]);
        }
      case ProgressModuleData():
        row(
          [
            '所属节点',
            '课程号',
            '课程',
            '修读状态',
            '学分',
            '性质',
            '类别',
            '计划内',
            '成绩学期',
            '成绩',
            '绩点',
            '建议修读学期',
          ].map(t),
        );
        for (final (path, c) in m.flatCourses) {
          row([
            t(path),
            t(c.courseCode),
            t(c.courseName),
            t(c.status),
            n(_S.formatCredits(c.credits)),
            t(c.nature),
            t(c.category),
            c.inPlan ? '是' : '否',
            t(c.scoreTerm),
            t(c.score),
            c.gradePoint == null ? '' : n(_S.formatPoints(c.gradePoint!)),
            t(c.suggestedTerm),
          ]);
        }
    }
    return b.toString();
  }

  /// 文件名：学业数据导出_20261013_1030.md，CSV 带模块名。
  static String fileName(
    GradesExportFormat format,
    AcademicExportDocument doc,
  ) {
    final t = doc.exportedAt;
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}';
    final suffix = format == GradesExportFormat.csv && doc.modules.isNotEmpty
        ? '_${doc.modules.first.module.label}'
        : '';
    return '学业数据导出${suffix}_$stamp.${format.extension}';
  }
}
