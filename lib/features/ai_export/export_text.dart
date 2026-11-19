/// 导出共用的文本原语：纯文本字段清洗与数值 / 时间格式化。
/// 具体模块的序列化见 `export_markdown.dart`。
///
/// 不依赖 Flutter，便于对中文、特殊字符与空值做单元测试。
abstract final class ExportText {
  // ── helpers ─────────────────────────────────────────────────────────────────

  /// 紧凑表格单元格：竖线替换为 `/`，换行压成空格，缺失显示 `—`。
  /// 默认纯文本导出不再使用 Markdown 反斜杠转义，减少无关符号噪音。
  static String cell(String? value) {
    final raw = value?.trim();
    if (raw == null || raw.isEmpty) return '—';
    return raw
        .replaceAll('|', '/')
        .replaceAll('\r\n', ' ')
        .replaceAll(RegExp(r'[\r\n]'), ' ');
  }

  /// 兼容旧名，等价于 [cell]。
  static String mdCell(String? value) => cell(value);

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
