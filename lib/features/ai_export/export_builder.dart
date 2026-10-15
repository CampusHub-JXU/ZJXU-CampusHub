import 'export_document.dart';
import 'export_markdown.dart';

/// 导出文件的扩展名与 MIME 类型：导出只有 Markdown 一种格式。
const String kExportExtension = 'md';
const String kExportMimeType = 'text/markdown';

/// 纯函数序列化：导出只输出 Markdown（正文见 `export_markdown.dart`）。
abstract final class ExportBuilder {
  static String markdown(AiExportDocument doc) => renderExportMarkdown(doc);

  /// 文件名：学业数据导出_20261013_1030.md
  static String fileName(AiExportDocument doc) {
    final t = doc.exportedAt;
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}';
    return '学业数据导出_$stamp.$kExportExtension';
  }
}
