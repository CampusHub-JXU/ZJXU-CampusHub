import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/plain_list.dart';
import 'changxing_jiada_model.dart';

/// 统计单元：标签在上、数字在下（design-guidelines §1.1 规则 4）。
///
/// [emphasized] 为当前最重要的状态（「办理中」）：行值档 24 w700 + 主色，
/// 是有数据时的唯一焦点数字；其余次级统计用轻量档（`listTitle` 16 w600）
/// 中性色，避免三个数字等权抢眼。零值统一转 `onSurfaceVariant`，让「0」
/// 安静下来。数字一律等宽（`FontFeature.tabularFigures()`）。
class ChangxingMetric extends StatelessWidget {
  const ChangxingMetric({
    super.key,
    required this.value,
    required this.label,
    this.emphasized = true,
  });

  final int value;
  final String label;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final zero = value == 0;
    final valueStyle = emphasized
        ? text.rowValue.copyWith(color: zero ? cs.onSurfaceVariant : cs.primary)
        : text.listTitle.copyWith(
            fontWeight: FontWeight.w600,
            color: zero ? cs.onSurfaceVariant : cs.onSurface,
            fontFeatures: const [FontFeature.tabularFigures()],
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: text.meta),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text('$value', maxLines: 1, style: valueStyle),
        ),
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

/// 个人资料轻量折叠：默认收起，标题行始终可发现、可点开；展开后按需展示
/// 学号 / 联系电话 / 紧急联系人（紧急联系人不会被藏到无路径可达）。
/// 纯展示，不改任何业务字段；展开是即时切换，不加动画（天然尊重「移除动画」）。
class ChangxingProfileDetails extends StatefulWidget {
  const ChangxingProfileDetails({super.key, required this.profile});

  final ChangxingUserProfile profile;

  @override
  State<ChangxingProfileDetails> createState() =>
      _ChangxingProfileDetailsState();
}

class _ChangxingProfileDetailsState extends State<ChangxingProfileDetails> {
  bool _expanded = false;

  String _orDash(String value) => value.isEmpty ? '—' : value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final profile = widget.profile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          expanded: _expanded,
          label: '个人资料',
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.chip),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('个人资料', style: text.label),
                          const SizedBox(height: 2),
                          Text(
                            '学号 · 联系电话 · 紧急联系人',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.meta,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: cs.outline,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 12),
          ChangxingInfoGrid(
            items: [
              (label: '学号', value: _orDash(profile.jobNo)),
              (label: '联系电话', value: _orDash(profile.phone)),
              (
                label: '紧急联系人',
                value: profile.emergencyContact.isEmpty
                    ? '—'
                    : '${profile.emergencyContact}  ${profile.emergencyPhone}',
              ),
            ],
          ),
        ],
      ],
    );
  }
}
