import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/glass_style_controller.dart';
import 'app_surface_style.dart';

/// 分组列表页的左右留白（我的 / 设置 / 关于共用，与首页功能区一致）。
const double kPlainListGutter = 24;

/// 分组之间的留白。
const double kPlainListGroupGap = 20;

/// 行内左右内边距：图标与文字都从这条竖线起排。
const double kPlainListRowInset = 16;

/// 分组卡片：与功能区磁贴（`AppTileSurface`）同一套卡面配方——平色 /
/// 玻璃 tint 填充 + squircle 圆角。
///
/// 行之间不画分隔线：卡片本身已经把相关的行收拢在一起，图标与文字靠固定
/// 左边距在竖直方向对齐。
class PlainListGroup extends StatelessWidget {
  const PlainListGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final style = GlassStyleController.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: style.enabled,
      builder: (context, glassEnabled, _) => ValueListenableBuilder<double>(
        valueListenable: style.tintOpacity,
        builder: (context, tintOpacity, _) => Material(
          color: appSurfaceColor(
            cs: cs,
            isDark: isDark,
            glassEnabled: glassEnabled,
            tintAlpha: isDark ? tintOpacity * 0.86 : tintOpacity,
          ),
          shape: RoundedSuperellipseBorder(borderRadius: AppRadius.tileBorder),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            // 首尾行与卡片圆角之间留一点呼吸，行与行之间不再加任何东西。
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ),
    );
  }
}

/// 分组小标题：13 号灰字，以 header 语义暴露给读屏。
class PlainSectionHeader extends StatelessWidget {
  const PlainSectionHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Padding(
        // 左缘贴齐卡片边缘，与功能页标题同一条线。
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 列表行：标题在左；右侧依次是灰色值 [value]、自定义控件 [trailing]、箭头。
///
/// 值放右侧、不写成句子（「开学日  9月1日」）。[subtitle] 只留给确实需要
/// 解释的例外情况，默认不用。箭头默认在可点且没有 [trailing] 时出现。
class PlainListRow extends StatelessWidget {
  const PlainListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.value,
    this.valueKey,
    this.emphasizeValue = false,
    this.trailing,
    this.onTap,
    this.titleColor,
    this.showChevron,
    this.leading,
  });

  /// 行首图标（通常是 `AppIconBadge` 小号），tab 页用它对齐功能区的磁贴。
  final Widget? leading;

  final String title;
  final String? subtitle;
  final String? value;
  final Key? valueKey;

  /// 值需要引起注意时（如「发现新版本」）改用主题色。
  final bool emphasizeValue;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? titleColor;
  final bool? showChevron;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final subtitleText = subtitle;
    final valueText = value;
    final chevron = showChevron ?? (onTap != null && trailing == null);
    final tappable = onTap != null;
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            height: 1.3,
            color: titleColor ?? cs.onSurface,
          ),
        ),
        if (subtitleText != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitleText,
            style: TextStyle(
              fontSize: 13,
              height: 1.3,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
    return Semantics(
      button: tappable ? true : null,
      enabled: tappable ? true : null,
      child: MergeSemantics(
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              // chevron 字形左右各带约 6 的透明边，右内边距相应收回，
              // 让箭头可见笔画到卡片右缘的距离与左侧内容一致。
              padding: EdgeInsets.fromLTRB(
                kPlainListRowInset,
                8,
                chevron ? kPlainListRowInset - 6 : kPlainListRowInset,
                8,
              ),
              child: Row(
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 12)],
                  // 标题与值共用一段横向空间：标题按内容宽度，值贴右对齐；
                  // 否则两者各占一半，值和箭头会悬在行中间。
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(child: titleBlock),
                        if (valueText != null) ...[
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              valueText,
                              key: valueKey,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: emphasizeValue
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: emphasizeValue
                                    ? cs.primary
                                    : cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 12),
                    trailing!,
                  ],
                  if (chevron) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.chevron_right, size: 20, color: cs.outline),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
