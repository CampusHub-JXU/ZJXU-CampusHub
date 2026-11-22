import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';

/// 一个筛选选项。
class AppFilterOption<T> {
  const AppFilterOption(this.value, this.label);

  final T value;
  final String label;
}

/// 一行横向筛选栏（`wrap == false`）与换行筛选块（`wrap == true`）：
///
/// * 横向模式：极简文字下划线栏，选中项以 `cs.onSurface` + `w600` 与底部
///   2dp `cs.primary` 短线标识，无灰底块。
/// * 换行模式（「筛选」弹层等）：8dp 圆角轻描边小块，未选中透明底 +
///   `cs.outlineVariant` 轻描边，选中 `cs.secondaryContainer` 填充。
/// * 更多维度收进「筛选」弹层，不把多个下拉横排在一行；`.multi` 为多选。
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
    final reduced = AppMotion.reduced(context);
    bool isSelected(T value) =>
        selectedValues?.contains(value) ?? value == selected;

    if (wrap) {
      return Padding(
        padding: padding,
        child: Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final option in options)
              _FilterWrapChip(
                label: option.label,
                selected: isSelected(option.value),
                labelStyle: labelStyle,
                colorScheme: cs,
                reduced: reduced,
                onTap: () => onSelected(option.value),
              ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: padding,
      child: Row(
        children: [
          for (final (index, option) in options.indexed) ...[
            if (index > 0) const SizedBox(width: AppSpacing.xs),
            _FilterUnderlineTab(
              label: option.label,
              selected: isSelected(option.value),
              labelStyle: labelStyle,
              colorScheme: cs,
              reduced: reduced,
              onTap: () => onSelected(option.value),
            ),
          ],
        ],
      ),
    );
  }
}

class _FilterUnderlineTab extends StatelessWidget {
  const _FilterUnderlineTab({
    required this.label,
    required this.selected,
    required this.labelStyle,
    required this.colorScheme,
    required this.reduced,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final TextStyle labelStyle;
  final ColorScheme colorScheme;
  final bool reduced;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(8);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40, minWidth: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: labelStyle.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected
                          ? colorScheme.onSurface
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 5),
                  AnimatedOpacity(
                    opacity: selected ? 1 : 0,
                    duration: reduced ? Duration.zero : AppMotion.quick,
                    curve: AppMotion.standard,
                    child: Container(
                      width: 20,
                      height: 2,
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterWrapChip extends StatelessWidget {
  const _FilterWrapChip({
    required this.label,
    required this.selected,
    required this.labelStyle,
    required this.colorScheme,
    required this.reduced,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final TextStyle labelStyle;
  final ColorScheme colorScheme;
  final bool reduced;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(8);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? colorScheme.secondaryContainer : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected ? Colors.transparent : colorScheme.outlineVariant,
            width: 0.9,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        animationDuration: reduced ? Duration.zero : AppMotion.quick,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: Text(
                  label,
                  style: labelStyle.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected
                        ? colorScheme.onSecondaryContainer
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
