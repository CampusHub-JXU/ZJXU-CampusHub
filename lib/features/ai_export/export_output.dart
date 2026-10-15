import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

/// 保存文件的可注入点，测试用替身替换 file_picker；返回保存路径，
/// 用户取消时返回 `null`。
typedef ExportFileSaver = Future<String?> Function(
  String fileName,
  String extension,
  Uint8List bytes,
);

/// 当前生效的文件保存器。
ExportFileSaver exportFileSaver = defaultExportFileSaver;

/// 默认实现：file_picker 的「另存为」在移动端会写入字节并返回保存路径。
Future<String?> defaultExportFileSaver(
  String fileName,
  String extension,
  Uint8List bytes,
) {
  return FilePicker.platform.saveFile(
    dialogTitle: '保存学业数据导出',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: [extension],
    bytes: bytes,
  );
}

/// 系统分享的结果。**只有「用户选了目标应用」才算 [shared]**；
/// 取消分享不是成功，也不意味着数据被上传。
enum ExportShareOutcome { shared, dismissed, unavailable }

/// 一次分享的载荷：Markdown 以纯文本分享，JSON / CSV 以内存文件分享。
class ExportSharePayload {
  const ExportSharePayload({
    required this.fileName,
    required this.mimeType,
    required this.text,
    required this.asText,
  });

  final String fileName;
  final String mimeType;
  final String text;
  final bool asText;
}

/// 系统分享的可注入点（测试替身）。
typedef ExportSharer = Future<ExportShareOutcome> Function(
  ExportSharePayload payload,
);

ExportSharer exportSharer = defaultExportSharer;

/// 默认实现：只调用系统分享菜单（Android Sharesheet），不绑定任何 App。
Future<ExportShareOutcome> defaultExportSharer(
  ExportSharePayload payload,
) async {
  final params = payload.asText
      ? ShareParams(text: payload.text, subject: payload.fileName)
      : ShareParams(
          files: [
            XFile.fromData(
              Uint8List.fromList(utf8.encode(payload.text)),
              mimeType: payload.mimeType,
              name: payload.fileName,
            ),
          ],
          fileNameOverrides: [payload.fileName],
          subject: payload.fileName,
        );
  final result = await SharePlus.instance.share(params);
  return switch (result.status) {
    ShareResultStatus.success => ExportShareOutcome.shared,
    ShareResultStatus.dismissed => ExportShareOutcome.dismissed,
    ShareResultStatus.unavailable => ExportShareOutcome.unavailable,
  };
}
