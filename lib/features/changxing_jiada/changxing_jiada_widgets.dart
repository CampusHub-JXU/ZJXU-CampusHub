import 'package:flutter/material.dart';

import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/plain_list.dart';
import 'changxing_jiada_model.dart';

/// 统计单元：行值档数字（24，等宽）+ 小标签（设计规范 §1.1 数字分档）。
class ChangxingMetric extends StatelessWidget {
  const ChangxingMetric({super.key, required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final text = context.appText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$value', style: text.rowValue.copyWith(height: 1)),
        const SizedBox(height: 6),
        Text(label, style: text.meta),
      ],
    );
  }
}

/// 两列信息栅格：标签在上、值在下。
class ChangxingInfoGrid extends StatelessWidget {
  const ChangxingInfoGrid({super.key, required this.items, this.columns = 2});

  final List<({String label, String value})> items;
  final int columns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 16.0;
        final cellWidth =
            (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: 14,
          children: [
            for (final item in items)
              SizedBox(
                width: cellWidth,
                child: _InfoCell(label: item.label, value: item.value),
              ),
          ],
        );
      },
    );
  }
}

class _InfoCell extends StatelessWidget {
  const _InfoCell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: context.appText.meta),
        const SizedBox(height: 3),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

/// 表单里的区域选择行：右侧显示已选区域名，未选时显示「请选择」。
PlainListRow changxingAreaRow({
  required String title,
  required ChangxingAreaSelection? selection,
  required VoidCallback onTap,
}) {
  return PlainListRow(
    title: title,
    value: selection?.displayName ?? '请选择',
    onTap: onTap,
  );
}

/// 表单里的附件行：右侧显示文件名 / 「未上传」，上传中换成小 spinner。
PlainListRow changxingAttachmentRow({
  required String label,
  required bool uploading,
  required VoidCallback onTap,
}) {
  return PlainListRow(
    title: '附件',
    value: label.isEmpty ? '未上传' : label,
    trailing: uploading
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : null,
    showChevron: !uploading,
    onTap: uploading ? null : onTap,
  );
}

class ChangxingEmptyApplications extends StatelessWidget {
  const ChangxingEmptyApplications({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final text = context.appText;
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 20),
      child: Column(
        children: [
          Icon(Icons.inbox_outlined, size: 30, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text('暂无申请记录', style: text.rowTitle),
          const SizedBox(height: 4),
          Text('发起办理后会在这里显示进度', style: text.secondary),
        ],
      ),
    );
  }
}
