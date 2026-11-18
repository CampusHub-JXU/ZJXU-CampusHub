import 'package:material_ui/material_ui.dart';

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
/// 外观与 `SegmentedButton` 同属一档（`AppRadius.control` 圆角矩形、中性容器
/// 填充、无描边），避免胶囊与分段控件在同屏出现两套轮廓：选中
/// `secondaryContainer`、不显示对勾、未选中 `surfaceContainerHighest`、
/// `secondary` 字（13）。更多维度收进「筛选」弹层，不要把多个下拉横排在
/// 一行；弹层里用 [wrap] 换行排列。
class AppFilterChips<T> extends StatelessWidget {
  const AppFilterChips({
    super.key,
    required this.options,
    required T this.selected,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.pageMargin,
    ),
    this.wrap = false,
  }) : selectedValues = null;

  /// 多选：[selectedValues] 里的选项都显示为选中，点按回调 [onSelected]
  /// （由调用方决定切换逻辑，如至少保留一项）。
  const AppFilterChips.multi({
    super.key,
    required this.options,
    required Set<T> this.selectedValues,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.pageMargin,
    ),
    this.wrap = false,
  }) : selected = null;

  final List<AppFilterOption<T>> options;
  final T? selected;
  final Set<T>? selectedValues;
  final ValueChanged<T> onSelected;
  final EdgeInsetsGeometry padding;

  /// 换行排列（「筛选」弹层里选项多时，如学院），不横向滚动。
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labelStyle = context.appText.secondary;
    bool isSelected(T value) =>
        selectedValues?.contains(value) ?? value == selected;
    final chips = [
      for (final option in options)
        ChoiceChip(
          label: Text(option.label),
          selected: isSelected(option.value),
          onSelected: (_) => onSelected(option.value),
          showCheckmark: false,
          selectedColor: cs.secondaryContainer,
          backgroundColor: cs.surfaceContainerHighest,
          labelStyle: labelStyle.copyWith(
            color: isSelected(option.value)
                ? cs.onSecondaryContainer
                : cs.onSurfaceVariant,
          ),
          side: BorderSide.none,
          shape: RoundedRectangleBorder(borderRadius: AppRadius.chipBorder),
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
