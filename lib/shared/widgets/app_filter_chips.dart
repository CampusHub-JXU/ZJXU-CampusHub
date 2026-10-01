import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';

/// 一个筛选选项。
class AppFilterOption<T> {
  const AppFilterOption(this.value, this.label);

  final T value;
  final String label;
}

/// 一行横向可滑的单选 chip（docs/ui-unification-plan.md §4.5）：
/// 最常用的那个筛选维度平铺在这里（学期、分类、通知类型）。
///
/// 样式与成绩页学期 chip 一致：选中 `secondaryContainer`、不显示对勾、
/// stadium 形状、未选中细描边、`secondary` 字（13）。更多维度收进
/// 「筛选」弹层，不要把多个下拉横排在一行；弹层里用 [wrap] 换行排列。
class AppFilterChips<T> extends StatelessWidget {
  const AppFilterChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.pageMargin,
    ),
    this.wrap = false,
  });

  final List<AppFilterOption<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final EdgeInsetsGeometry padding;

  /// 换行排列（「筛选」弹层里选项多时，如学院），不横向滚动。
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labelStyle = context.appText.secondary;
    final chips = [
      for (final option in options)
        ChoiceChip(
          label: Text(option.label),
          selected: option.value == selected,
          onSelected: (_) => onSelected(option.value),
          showCheckmark: false,
          selectedColor: cs.secondaryContainer,
          labelStyle: labelStyle.copyWith(
            color: option.value == selected
                ? cs.onSecondaryContainer
                : cs.onSurfaceVariant,
          ),
          side: option.value == selected
              ? BorderSide.none
              : BorderSide(color: cs.outlineVariant),
          shape: const StadiumBorder(),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
    ];
    if (wrap) {
      return Padding(
        padding: padding,
        child: Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: chips,
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: padding,
      child: Row(
        children: [
          for (final (index, chip) in chips.indexed) ...[
            if (index > 0) const SizedBox(width: AppSpacing.sm),
            chip,
          ],
        ],
      ),
    );
  }
}
