import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';

/// C2 列表数据页的单列行（成绩、考试、通知等，docs/ui-unification-plan.md §4.4）。
///
/// 左侧：标题（`rowTitle` 15 w600，单行）+ 可选的元信息（`meta` 12，用「 · 」
/// 连接）+ 可选的明细行（`secondary` 13，每行一条）；右侧：[trailing]
/// （行值 / 状态标签），垂直居中。
///
/// 底色是平色 `surfaceContainerLow` + squircle 圆角，**不做背景模糊**：
/// 列表里每一行都模糊会超出每屏模糊预算（design-guidelines §2），亚克力
/// 只留给 `AppTileSurface` 这类少量磁贴。
class AppListTile extends StatelessWidget {
  const AppListTile({
    super.key,
    required this.title,
    this.titleTrailing,
    this.meta,
    this.details = const [],
    this.trailing,
    this.onTap,
    this.dimmed = false,
  });

  final String title;

  /// 紧跟标题的小元素（如「重修」标签），不参与右侧对齐。
  final Widget? titleTrailing;

  /// 标题下一行的元信息，如「4 学分 · 考试 · 绩点 4.5」。
  final String? meta;

  /// 元信息下方的明细，每条一行、单行省略（时间、地点、座号…）。
  final List<String> details;

  /// 右侧关键值或状态标签。
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 已结束 / 已失效的条目：标题降为次要色。
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final metaText = meta;
    final titleStyle = dimmed
        ? text.rowTitle.copyWith(color: cs.onSurfaceVariant)
        : text.rowTitle;

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
            ),
            if (titleTrailing != null) ...[
              const SizedBox(width: AppSpacing.sm),
              titleTrailing!,
            ],
          ],
        ),
        if (metaText != null && metaText.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            metaText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.meta,
          ),
        ],
        for (final (index, line) in details.indexed) ...[
          SizedBox(height: index == 0 ? 6 : 2),
          Text(
            line,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.secondary,
          ),
        ],
      ],
    );

    return Material(
      color: cs.surfaceContainerLow,
      shape: RoundedSuperellipseBorder(borderRadius: AppRadius.cardBorder),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              Expanded(child: body),
              if (trailing != null) ...[
                const SizedBox(width: AppSpacing.md),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
