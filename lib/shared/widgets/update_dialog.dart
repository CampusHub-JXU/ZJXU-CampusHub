import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/update/update_model.dart';
import 'app_feedback.dart';
import 'glass_dialog_route.dart';

Future<void> showUpdateDialog(BuildContext context, AppRelease release) {
  final publishedAt = _formatDate(release.publishedAt);
  final changelog = release.changelog.isEmpty ? '暂无更新说明' : release.changelog;

  // 玻璃化弹层：材质/圆角由 showGlassDialog 提供，AlertDialog 只负责排版；
  // 玻璃关闭时自动降级为实色表面。
  return showGlassDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text('发现新版本 v${release.version}'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('发布时间：$publishedAt'),
                const SizedBox(height: 12),
                const Text(
                  '更新内容',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                SelectableText(changelog),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('稍后再说'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              if (!context.mounted) return;
              final uri = Uri.tryParse(release.launchUrl);
              if (uri == null) {
                AppFeedback.toast(context, '更新链接无效');
                return;
              }
              final launched = await launchUrl(
                uri,
                mode: LaunchMode.externalApplication,
              );
              if (!launched && context.mounted) {
                AppFeedback.toast(context, '无法打开更新链接');
              }
            },
            child: Text(release.hasDownloadUrl ? '下载 APK' : '查看版本'),
          ),
        ],
      );
    },
  );
}

String _formatDate(DateTime value) {
  final year = value.year.toString().padLeft(4, '0');
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$year-$month-$day $hour:$minute';
}
