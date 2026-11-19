import 'export_document.dart';
import 'export_markdown.dart';

/// 导出文件的扩展名与 MIME 类型：默认导出高信息熵紧凑纯文本（无 Markdown 噪音）。
const String kExportExtension = 'txt';
const String kExportMimeType = 'text/plain';

/// 纯函数序列化：输出紧凑纯文本（正文见 `export_markdown.dart`）。
abstract final class ExportBuilder {
  static String plainText(AiExportDocument doc) => renderExportMarkdown(doc);

  /// 兼容旧调用名，实际输出紧凑纯文本。
  static String markdown(AiExportDocument doc) => plainText(doc);

  /// 文件名：学业数据导出_20261013_1030.txt
  static String fileName(AiExportDocument doc) {
    final t = doc.exportedAt;
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}';
    return '学业数据导出_$stamp.$kExportExtension';
  }
}
