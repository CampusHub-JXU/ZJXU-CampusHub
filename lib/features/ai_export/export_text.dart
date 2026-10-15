/// 导出格式。
enum ExportFormat {
  markdown('Markdown', 'md'),
  json('JSON', 'json'),
  csv('CSV', 'csv');

  const ExportFormat(this.label, this.extension);

  final String label;
  final String extension;
}

/// 导出共用的文本原语：CSV 转义（含公式注入中和）、Markdown 单元格转义与
/// 数值 / 时间格式化。具体模块的序列化见 `export_builder.dart`。
///
/// 不依赖 Flutter，便于对中文、特殊字符、空值与 CSV 转义做单元测试。
abstract final class ExportText {
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
