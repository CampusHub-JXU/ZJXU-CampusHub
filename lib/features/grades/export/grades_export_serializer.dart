import '../grades_model.dart';

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

/// 成绩导出范围：当前选中的学期，或全部已加载学期。
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

/// 导出共用的文本原语：CSV 转义（含公式注入中和）、Markdown 单元格转义与
/// 数值 / 时间格式化。具体模块的序列化见 `academic_export_builder.dart`。
///
/// 不依赖 Flutter，便于对中文、特殊字符、空值与 CSV 转义做单元测试。
abstract final class GradesExportSerializer {
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
  static String csvNumberField(String value) => _quoteCsvField(value);

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
  static String mdCell(String? value) {
    final raw = value?.trim();
    if (raw == null || raw.isEmpty) return '—';
    return raw
        .replaceAll('|', '\\|')
        .replaceAll('\r\n', ' ')
        .replaceAll(RegExp(r'[\r\n]'), ' ');
  }

  static String formatPoints(double value) =>
      value == 0 ? '0' : value.toStringAsFixed(2);

  static String formatCredits(double value) => value.toStringAsFixed(1);

  static String formatDateTime(DateTime? value) {
    if (value == null) return '未知';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }
}
