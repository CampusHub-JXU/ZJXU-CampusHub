import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 复制文本到剪贴板并弹轻提示；messenger 在 await 前捕获，免去 mounted 检查。
/// PlatformException（部分 ROM 限制剪贴板）降级为「复制失败」提示。
Future<void> copyTextWithFeedback(BuildContext context, String text) async {
  final messenger = ScaffoldMessenger.of(context);
  var copied = false;
  try {
    await Clipboard.setData(ClipboardData(text: text));
    copied = true;
  } on PlatformException {
    copied = false;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(copied ? '链接已复制' : '复制失败')));
}
