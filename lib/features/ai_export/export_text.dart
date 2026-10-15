/// 导出共用的文本原语：Markdown 单元格转义与数值 / 时间格式化。
/// 具体模块的序列化见 `export_markdown.dart`。
///
/// 不依赖 Flutter，便于对中文、特殊字符与空值做单元测试。
abstract final class ExportText {
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
