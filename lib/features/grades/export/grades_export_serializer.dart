import 'dart:convert';

import '../grades_model.dart';

/// 成绩导出的 schema 版本；JSON 结构变化时递增。首版固定为 1。
const int kGradesExportSchemaVersion = 1;

/// 导出格式。
enum GradesExportFormat {
  markdown('Markdown', 'md'),
  json('JSON', 'json'),
  csv('CSV', 'csv');

  const GradesExportFormat(this.label, this.extension);

  final String label;
  final String extension;
}

/// 白名单后的单条成绩：只保留学业字段。
///
/// 刻意从 [GradeEntry] 逐字段映射，**绝不**整体序列化成绩模型（其
/// `toJson` 使用教务原始键，且未来若模型加入身份字段会被无差别导出）。
/// 学号 / 姓名 / 账号凭据 / Cookie / Token 从不出现在此处。
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
  final String? examType;
  final String? assessmentMethod;
  final String? courseRequirement;

  /// 从模型只取学业字段；空串归一为 `null`（缺失就是缺失，不猜测）。
  factory GradesExportRecord.fromEntry(GradeEntry entry) {
    String? optional(String raw) {
      final trimmed = raw.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    return GradesExportRecord(
      courseName: entry.courseName.trim(),
      grade: optional(entry.grade),
      percentageScore: optional(entry.percentageScore),
      gpaPoints: entry.gpaPoints,
      credits: entry.credits,
      academicYear: entry.academicYear.trim(),
      semester: entry.semester.trim(),
      examType: optional(entry.examType),
      assessmentMethod: optional(entry.assessmentMethod),
      courseRequirement: optional(entry.courseRequirement),
    );
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

/// 导出范围：本次只覆盖「当前已加载」成绩所在的学期。
class GradesExportScope {
  const GradesExportScope({
    required this.label,
    this.academicYear,
    this.semester,
  });

  /// 展示用范围标签，如 `2025–26 春` 或 `全部已加载学期`。
  final String label;
  final String? academicYear;
  final String? semester;
}

/// 一次导出的完整快照数据（含归属元信息）。
class GradesExportDocument {
  const GradesExportDocument({
    required this.exportedAt,
    required this.scope,
    required this.records,
    this.lastUpdatedAt,
    this.dataSource,
  });

  final DateTime exportedAt;
  final GradesExportScope scope;
  final List<GradesExportRecord> records;

  /// 页面已知的最近成功更新时间；未知为 `null`。
  final DateTime? lastUpdatedAt;

  /// 数据来源（缓存 / 本次读取）。页面无法确证时为 `null`，不猜测。
  final String? dataSource;

  double get totalCredits => records.fold(0, (sum, r) => sum + r.credits);

  GradesExportDocument withSource(String? source) => GradesExportDocument(
    exportedAt: exportedAt,
    scope: scope,
    records: records,
    lastUpdatedAt: lastUpdatedAt,
    dataSource: source,
  );
}

/// 纯函数序列化：Markdown（默认）/ 版本化 JSON / 带 BOM 的 CSV。
///
/// 不依赖 Flutter，便于对中文、特殊字符、空值与 CSV 转义做单元测试。
abstract final class GradesExportSerializer {
  static const String _disclaimer = '仅导出当前已加载的成绩，不会重新联网获取，也不代表学校官方学业审核结果。';

  static String encode(GradesExportFormat format, GradesExportDocument doc) {
    return switch (format) {
      GradesExportFormat.markdown => markdown(doc),
      GradesExportFormat.json => jsonString(doc),
      GradesExportFormat.csv => csv(doc),
    };
  }

  // ── Markdown ────────────────────────────────────────────────────────────────

  static String markdown(GradesExportDocument doc) {
    final b = StringBuffer()
      ..writeln('# 成绩导出')
      ..writeln()
      ..writeln('> $_disclaimer')
      ..writeln('>')
      ..writeln('> 导出时间：${_formatDateTime(doc.exportedAt)}')
      ..writeln('> 学期范围：${_mdCell(doc.scope.label)}')
      ..writeln('> 课程数：${doc.records.length}')
      ..writeln('> 学分合计：${_formatCredits(doc.totalCredits)}')
      ..writeln('> 最后更新：${_formatDateTime(doc.lastUpdatedAt)}')
      ..writeln('> 数据来源：${_mdCell(doc.dataSource ?? '未知')}')
      ..writeln()
      ..writeln('## 成绩')
      ..writeln()
      ..writeln('| 课程 | 成绩 | 百分制 | 绩点 | 学分 | 学年 | 学期 | 考试性质 | 考核方式 | 课程性质 |')
      ..writeln(
        '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |',
      );
    for (final r in doc.records) {
      b.writeln(
        '| ${_mdCell(r.courseName)} '
        '| ${_mdCell(r.grade)} '
        '| ${_mdCell(r.percentageScore)} '
        '| ${_formatPoints(r.gpaPoints)} '
        '| ${_formatCredits(r.credits)} '
        '| ${_mdCell(r.academicYear)} '
        '| ${_mdCell(r.semester)} '
        '| ${_mdCell(r.examType)} '
        '| ${_mdCell(r.assessmentMethod)} '
        '| ${_mdCell(r.courseRequirement)} |',
      );
    }
    return b.toString().trimRight();
  }

  // ── JSON ────────────────────────────────────────────────────────────────────

  static String jsonString(GradesExportDocument doc) {
    final payload = <String, dynamic>{
      'schemaVersion': kGradesExportSchemaVersion,
      'module': 'grades',
      'exportedAt': doc.exportedAt.toIso8601String(),
      'scope': {
        'label': doc.scope.label,
        'academicYear': doc.scope.academicYear,
        'semester': doc.scope.semester,
      },
      'lastUpdatedAt': doc.lastUpdatedAt?.toIso8601String(),
      'dataSource': doc.dataSource,
      'recordCount': doc.records.length,
      'totalCredits': doc.totalCredits,
      'disclaimer': _disclaimer,
      'grades': [for (final r in doc.records) r.toJson()],
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  // ── CSV ─────────────────────────────────────────────────────────────────────

  /// Excel 兼容（UTF-8 BOM）；只导出成绩表，不混入其他模块。
  static String csv(GradesExportDocument doc) {
    final b = StringBuffer()
      ..write(csvBom)
      ..writeln(
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
        ].map(csvField).join(','),
      );
    for (final r in doc.records) {
      b.writeln(
        [
          csvField(r.courseName),
          csvField(r.grade),
          csvField(r.percentageScore),
          _csvNumberField(_formatPoints(r.gpaPoints)),
          _csvNumberField(_formatCredits(r.credits)),
          csvField(r.academicYear),
          csvField(r.semester),
          csvField(r.examType),
          csvField(r.assessmentMethod),
          csvField(r.courseRequirement),
        ].join(','),
      );
    }
    return b.toString();
  }

  /// Excel 识别 UTF-8 的字节序标记，放在 CSV 首部。
  static const String csvBom = '\uFEFF';

  /// CSV 单元格转义：含逗号 / 引号 / 换行时用双引号包裹，内部引号翻倍。
  /// `null` 与空串都输出空单元格（缺失不猜测）。
  static String csvField(String? value) {
    var raw = value ?? '';
    if (raw.isEmpty) return '';
    // Remote text can be interpreted as a formula by spreadsheet software.
    // Drop leading control characters first so tab/newline-prefixed formulas
    // receive the same protection as formulas at the start of a cell.
    raw = raw.replaceFirst(RegExp(r'^[\x00-\x1F\x7F-\x9F]+'), '');
    if (raw.isEmpty) return '';
    if (RegExp(r'^[=+\-@]').hasMatch(raw)) raw = "'$raw";
    return _quoteCsvField(raw);
  }

  /// Numeric cells are generated from parsed numeric values, so a leading
  /// minus sign is data and must remain numeric in spreadsheet applications.
  static String _csvNumberField(String value) => _quoteCsvField(value);

  static String _quoteCsvField(String raw) {
    final needsQuotes =
        raw.contains(',') ||
        raw.contains('"') ||
        raw.contains('\n') ||
        raw.contains('\r');
    if (!needsQuotes) return raw;
    return '"${raw.replaceAll('"', '""')}"';
  }

  // ── helpers ─────────────────────────────────────────────────────────────────

  /// Markdown 表格单元格：竖线转义，换行压成空格，缺失显示 `—`。
  static String _mdCell(String? value) {
    final raw = value?.trim();
    if (raw == null || raw.isEmpty) return '—';
    return raw
        .replaceAll('|', '\\|')
        .replaceAll('\r\n', ' ')
        .replaceAll(RegExp(r'[\r\n]'), ' ');
  }

  static String _formatPoints(double value) =>
      value == 0 ? '0' : value.toStringAsFixed(2);

  static String _formatCredits(double value) => value.toStringAsFixed(1);

  static String _formatDateTime(DateTime? value) {
    if (value == null) return '未知';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }
}
