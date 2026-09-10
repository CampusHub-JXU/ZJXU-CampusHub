import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 复制文本到剪贴板并弹轻提示；messenger 在 await 前捕获，免去 mounted 检查。
Future<void> copyTextWithFeedback(BuildContext context, String text) async {
  final messenger = ScaffoldMessenger.of(context);
  await Clipboard.setData(ClipboardData(text: text));
  messenger.showSnackBar(const SnackBar(content: Text('链接已复制')));
}
