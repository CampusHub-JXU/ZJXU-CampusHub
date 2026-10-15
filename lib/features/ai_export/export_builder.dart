import 'dart:convert';

import 'export_background.dart';
import 'export_document.dart';
import 'export_markdown.dart';
import 'export_model.dart';
import 'export_text.dart';

typedef _T = ExportText;

const String _disclaimer =
    '本文件由本机已加载 / 获取的数据整理生成，不代表学校官方学业审核结果；'
    '成绩、绩点与学分以教务系统为准。';

/// 纯函数序列化：Markdown（默认）/ 版本化 JSON / 逐模块 CSV。
abstract final class ExportBuilder {
  static String encode(
    ExportFormat format,
    AiExportDocument doc, {
    ExportModule? csvModule,
  }) {
    return switch (format) {
      ExportFormat.markdown => markdown(doc),
      ExportFormat.json => jsonString(doc),
      ExportFormat.csv => csv(doc, module: csvModule),
    };
  }

  static String markdown(AiExportDocument doc) => renderExportMarkdown(doc);

  // ── JSON ──────────────────────────────────────────────────────────────────

  /// 稳定结构：顶层键固定；每个所选模块都输出同一组元键，
  /// 未获取时数据键为 `null`（不用空数组伪装）。
  static String jsonString(AiExportDocument doc) {
    final payload = <String, dynamic>{
      'schemaVersion': kAiExportSchemaVersion,
      'exportedAt': doc.exportedAt.toUtc().toIso8601String(),
      'disclaimer': _disclaimer,
      'privacy': {'includesIdentity': false},
      'context': ExportBackground.from(doc).toJson(),
      'modules': {for (final m in doc.modules) m.module.key: _moduleJson(m)},
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  static Map<String, dynamic> _moduleJson(ExportModuleData m) {
    final has = m.status.hasData;
    final meta = <String, dynamic>{
      'status': m.status.key,
      'lastUpdatedAt': m.lastUpdatedAt?.toUtc().toIso8601String(),
      'dataSource': m.dataSource,
      'itemCount': m.itemCount,
      'scope': has ? m.scopeLabel : null,
    };
    List<Map<String, dynamic>>? list<R>(
      Iterable<R> rows,
      Map<String, dynamic> Function(R) toJson,
    ) => has ? [for (final r in rows) toJson(r)] : null;

    switch (m) {
      case MissingModuleData():
        return meta;
      case GradesModuleData():
        return {
          ...meta,
          'totalCredits': has ? m.totalCredits : null,
          'summary': has ? m.summary.toJson() : null,
          'terms': has
              ? [
                  for (final t in m.terms)
                    {
                      'academicYear': t.academicYear,
                      'semester': t.semester,
                      'courseCount': t.courseCount,
                      'credits': t.credits,
                      ...t.summary.toJson(),
                    },
                ]
              : null,
          'records': list(m.records, (r) => r.toJson()),
        };
      case ProgressModuleData():
        return {
          ...meta,
          'summary': m.summary?.toJson(),
          'requirements': list(m.nodes, (n) => n.toJson()),
        };
      case ScheduleModuleData():
        return {
          ...meta,
          'term': {
            'label': m.termLabel,
            'academicYear': m.academicYear,
            'termCode': m.termCode,
          },
          'changeRuleCount': m.changeRuleCount,
          'effectiveWeeks': list(m.weeks, (w) => w.toJson()),
          'courses': list(m.courses, (c) => c.toJson()),
        };
      case ExamsModuleData():
        return {...meta, 'records': list(m.records, (r) => r.toJson())};
      case SecondClassroomModuleData():
        return {
          ...meta,
          'creditsVerified': false,
          'checkedInCount': has ? m.checkedInCount : null,
          'checkedInNominalHours': has ? m.checkedInNominalHours : null,
          'enrolled': list(m.enrolled, (r) => r.toJson()),
        };
      case NoticesModuleData():
        return {
          ...meta,
          'windowDays': kNoticeWindowDays,
          'includesBody': false,
          'records': list(m.records, (r) => r.toJson()),
        };
      case PhysicalTestModuleData():
        return {...meta, 'records': list(m.records, (r) => r.toJson())};
    }
  }

  // ── CSV ───────────────────────────────────────────────────────────────────

  /// 逐模块 CSV：不同模块不会混进同一张表。[module] 指定时取该模块，否则取
  /// 文档中第一个有数据的模块。
  static String csv(AiExportDocument doc, {ExportModule? module}) {
    final pick = csvTarget(doc, module);
    return pick == null ? _T.csvBom : csvFor(pick);
  }

  /// CSV 实际导出的模块：显式指定且在文档内的优先，否则第一个有数据的模块。
  static ExportModuleData? csvTarget(
    AiExportDocument doc,
    ExportModule? module,
  ) {
    if (doc.modules.isEmpty) return null;
    for (final m in doc.modules) {
      if (m.module == module) return m;
    }
    return doc.modules.firstWhere(
      (m) => m.status.hasData,
      orElse: () => doc.modules.first,
    );
  }

  /// Excel 兼容（UTF-8 BOM）；未获取的模块只输出表头，不伪造行。
  static String csvFor(ExportModuleData m) {
    final b = StringBuffer()..write(_T.csvBom);
    void row(Iterable<String> cells) => b.writeln(cells.join(','));
    String t(String? v) => _T.csvField(v);
    String n(String v) => _T.csvNumberField(v);
    String yn(bool v) => v ? '是' : '否';
    String cr(double v) => n(_T.formatCredits(v));
    String pts(double v) => n(_T.formatPoints(v));
    String dt(DateTime? d) => d == null ? '' : _T.formatDateTime(d);
    void header(List<String> cells) => row(cells.map(t));

    switch (m) {
      case MissingModuleData():
        header(['说明']);
      case GradesModuleData():
        header([
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
        ]);
        for (final r in m.records) {
          row([
            t(r.courseName),
            t(r.grade),
            t(r.percentageScore),
            pts(r.gpaPoints),
            cr(r.credits),
            t(r.academicYear),
            t(r.semester),
            t(r.examType),
            t(r.assessmentMethod),
            t(r.courseRequirement),
          ]);
        }
      case ProgressModuleData():
        header([
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
          '补考成绩',
          '重修成绩',
          '建议修读学期',
        ]);
        for (final (path, c) in m.flatCourses) {
          row([
            t(path),
            t(c.courseCode),
            t(c.courseName),
            t(c.status),
            cr(c.credits),
            t(c.nature),
            t(c.category),
            yn(c.inPlan),
            t(c.scoreTerm),
            t(c.score),
            c.gradePoint == null ? '' : pts(c.gradePoint!),
            t(c.makeupScore),
            t(c.retakeScore),
            t(c.suggestedTerm),
          ]);
        }
      case ScheduleModuleData():
        header([
          '星期',
          '开始节',
          '结束节',
          '开始时间',
          '结束时间',
          '课程',
          '教师',
          '地点',
          '校区',
          '类型',
          '周次',
          '教务标记调课',
        ]);
        for (final c in m.courses) {
          row([
            n('${c.weekday}'),
            n('${c.startLesson}'),
            n('${c.endLesson}'),
            t(c.startTime),
            t(c.endTime),
            t(c.courseName),
            t(c.teacher),
            t(c.location),
            t(c.campus),
            t(c.courseType),
            t(c.weekRange),
            yn(c.hasScheduleChange),
          ]);
        }
      case ExamsModuleData():
        header([
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
        ]);
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
            yn(r.isRetake),
            t(r.academicYear),
            t(r.semester),
          ]);
        }
      case SecondClassroomModuleData():
        header(['活动', '类别', '主办', '开始', '结束', '地点', '标称学时', '已签到']);
        for (final r in m.enrolled) {
          row([
            t(r.title),
            t(r.category),
            t(r.organizer),
            t(dt(r.activityStart)),
            t(dt(r.activityEnd)),
            t(r.location),
            cr(r.creditHours),
            yn(r.checkedIn),
          ]);
        }
      case NoticesModuleData():
        header(['日期', '栏目', '标题', '链接']);
        for (final r in m.records) {
          row([t(r.date), t(r.category), t(r.title), t(r.url)]);
        }
      case PhysicalTestModuleData():
        header(['学年', '总分', '总评等级', '项目', '成绩', '得分', '等级']);
        for (final r in m.records) {
          if (r.items.isEmpty) {
            row([
              t(r.academicYear),
              t(r.totalScore),
              t(r.grade),
              '',
              '',
              '',
              '',
            ]);
          }
          for (final i in r.items) {
            row([
              t(r.academicYear),
              t(r.totalScore),
              t(r.grade),
              t(i.name),
              t(i.result),
              t(i.score),
              t(i.level),
            ]);
          }
        }
    }
    return b.toString();
  }

  /// 文件名：学业数据导出_20261013_1030.md，CSV 带模块名。
  static String fileName(
    ExportFormat format,
    AiExportDocument doc, {
    ExportModule? csvModule,
  }) {
    final t = doc.exportedAt;
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}';
    var suffix = '';
    if (format == ExportFormat.csv) {
      final target = csvTarget(doc, csvModule);
      if (target != null) suffix = '_${target.module.label}';
    }
    return '学业数据导出${suffix}_$stamp.${format.extension}';
  }
}
