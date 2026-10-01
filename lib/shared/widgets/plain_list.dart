import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/glass_style_controller.dart';
import 'app_surface_style.dart';

/// 分组列表页的左右留白，即 [AppSpacing.listGutter]（保留旧名兼容调用方）。
const double kPlainListGutter = AppSpacing.listGutter;

/// 分组之间的留白，即 [AppSpacing.listGroupGap]。
const double kPlainListGroupGap = AppSpacing.listGroupGap;

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

/// 分组小标题：13 w600 灰字（`AppTypography.label`），以 header 语义暴露给读屏。
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
        child: Text(title, style: context.appText.label),
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
    this.titleBadge,
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

  /// 标题后的小标签（如「耗电」），用 tertiaryContainer 色块提示代价。
  final String? titleBadge;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final subtitleText = subtitle;
    final valueText = value;
    final chevron = showChevron ?? (onTap != null && trailing == null);
    final tappable = onTap != null;
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 2,
          children: [
            Text(
              title,
              style: titleColor == null
                  ? text.listTitle
                  : text.listTitle.copyWith(color: titleColor),
            ),
            if (titleBadge != null) PlainTag(titleBadge!),
          ],
        ),
        if (subtitleText != null) ...[
          const SizedBox(height: 2),
          Text(subtitleText, style: text.secondary),
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
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
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

/// 行内小标签：tertiaryContainer 底 + 11 w600（`AppTypography.tag`）。
class PlainTag extends StatelessWidget {
  const PlainTag(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        child: Text(
          label,
          style: context.appText.tag.copyWith(color: cs.onTertiaryContainer),
        ),
      ),
    );
  }
}

/// 开关行：点整行即切换，开关本身挂 [switchKey] 便于测试定位。
///
/// [enabled] 为 false 时整行与开关一起置灰不可用（前置条件未满足、原生调用
/// 在途等）。
class PlainSwitchRow extends StatelessWidget {
  const PlainSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.titleBadge,
    this.switchKey,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final String? titleBadge;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Key? switchKey;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return PlainListRow(
      title: title,
      subtitle: subtitle,
      titleBadge: titleBadge,
      showChevron: false,
      onTap: enabled ? () => onChanged(!value) : null,
      trailing: Switch.adaptive(
        key: switchKey,
        value: value,
        onChanged: enabled ? onChanged : null,
      ),
    );
  }
}

/// 滑条行：标题在左、当前值在右（等宽数字），滑条下挂整行宽。
class PlainSliderRow extends StatelessWidget {
  const PlainSliderRow({
    super.key,
    required this.title,
    required this.value,
    required this.valueLabel,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.sliderKey,
  });

  final String title;
  final double value;
  final String valueLabel;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final int? divisions;
  final Key? sliderKey;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kPlainListRowInset),
            child: Row(
              children: [
                Expanded(child: Text(title, style: context.appText.listTitle)),
                const SizedBox(width: 12),
                Text(
                  valueLabel,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            // 档位只用于吸附，不画刻度点：20 档的点阵会让滑轨显得很碎。
            child: SliderTheme(
              data: SliderTheme.of(context)
                  .copyWith(tickMarkShape: SliderTickMarkShape.noTickMark),
              child: Slider(
                key: sliderKey,
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                label: valueLabel,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
