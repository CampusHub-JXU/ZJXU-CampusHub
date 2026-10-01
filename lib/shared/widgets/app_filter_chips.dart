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
/// 「筛选」弹层，不要把多个下拉横排在一行。
class AppFilterChips<T> extends StatelessWidget {
  const AppFilterChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.pageMargin,
    ),
  });

  final List<AppFilterOption<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labelStyle = context.appText.secondary;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: padding,
      child: Row(
        children: [
          for (final (index, option) in options.indexed) ...[
            if (index > 0) const SizedBox(width: AppSpacing.sm),
            Builder(
              builder: (context) {
                final isSelected = option.value == selected;
                return ChoiceChip(
                  label: Text(option.label),
                  selected: isSelected,
                  onSelected: (_) => onSelected(option.value),
                  showCheckmark: false,
                  selectedColor: cs.secondaryContainer,
                  labelStyle: labelStyle.copyWith(
                    color: isSelected
                        ? cs.onSecondaryContainer
                        : cs.onSurfaceVariant,
                  ),
                  side: isSelected
                      ? BorderSide.none
                      : BorderSide(color: cs.outlineVariant),
                  shape: const StadiumBorder(),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}
