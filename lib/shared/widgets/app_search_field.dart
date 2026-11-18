import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_design_tokens.dart';

/// 统一搜索框。
///
/// 收敛 service_hub (18) 与 grades (14) 搜索框圆角不一致；统一为
/// [AppRadius.input]。遵循 design-guidelines：输入框必须有明确轮廓与实色底。
class AppSearchField extends StatelessWidget {
  const AppSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onChanged,
    required this.onClear,
    this.focusNode,
    this.fillAlpha = 0.5,
    this.compact = false,
    this.borderless = false,
    this.autofocus = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  /// 由调用方持有的输入焦点节点。调用方需要根据「输入框本身是否聚焦」改变
  /// 外层容器样式时传入（在 `borderless` 形态下，外层卡面用它决定聚焦描边）。
  /// 为 null 时由内部 `TextField` 自建节点，行为不变。
  ///
  /// 注意：调用方必须用这个 [FocusNode]，不要再用包一层的 `Focus` 去读焦点——
  /// 祖先 `Focus.hasFocus` 会把卡片内其它可聚焦后代（如清除按钮）也算作聚焦，
  /// 输入框本身已失焦时它仍可能为真。
  final FocusNode? focusNode;
  final double fillAlpha;

  /// 紧凑胶囊形态：嵌入 AppBar 等窄高度位置，无描边、实色底。
  final bool compact;

  /// 无框形态：无底色、无描边（含聚焦态），由外层容器（如磁贴卡面）负责
  /// 底色与聚焦提示。
  final bool borderless;
  final bool autofocus;

  /// 按键盘「搜索」时触发；只在提交时才查询的页面（如第二课堂）用它。
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (compact) return _buildCompact(context, cs);

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final showClear = value.text.isNotEmpty;
        return TextField(
          controller: controller,
          focusNode: focusNode,
          textInputAction: TextInputAction.search,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          decoration: InputDecoration(
            hintText: hintText,
            isDense: borderless,
            // 无框形态按小号徽标几何排版（36dp 图标位 + 6dp 间距，加上输入框自带
            // 约 4dp 起始留白 ≈ 磁贴的 10dp），
            // 嵌进磁贴卡面时与相邻磁贴的徽标、标题左缘对齐。
            prefixIcon: borderless
                ? const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: SizedBox(
                      width: AppBadgeSize.smallBox,
                      height: AppBadgeSize.smallBox,
                      child: Icon(
                        Icons.search_rounded,
                        size: AppBadgeSize.smallIcon,
                      ),
                    ),
                  )
                : const Icon(Icons.search_rounded),
            prefixIconConstraints: borderless
                ? const BoxConstraints(minWidth: 0, minHeight: 0)
                : null,
            suffixIcon: showClear
                ? IconButton(
                    onPressed: onClear,
                    icon: const Icon(Icons.close_rounded),
                    tooltip: '清除搜索',
                    iconSize: borderless ? 20 : null,
                    padding: borderless ? EdgeInsets.zero : null,
                  )
                : null,
            // 无框形态固定 36dp 高：清除按钮出现 / 消失时卡面高度不跳。
            suffixIconConstraints: borderless
                ? const BoxConstraints.tightFor(width: 36, height: 36)
                : null,
            filled: !borderless,
            fillColor: borderless
                ? null
                : cs.surfaceContainerHighest.withValues(alpha: fillAlpha),
            border: borderless
                ? InputBorder.none
                : OutlineInputBorder(
                    borderRadius: AppRadius.inputBorder,
                    borderSide: BorderSide.none,
                  ),
            enabledBorder: borderless
                ? InputBorder.none
                : OutlineInputBorder(
                    borderRadius: AppRadius.inputBorder,
                    borderSide: BorderSide(
                      color: cs.outlineVariant.withValues(alpha: 0.45),
                    ),
                  ),
            focusedBorder: borderless
                ? InputBorder.none
                : OutlineInputBorder(
                    borderRadius: AppRadius.inputBorder,
                    borderSide: BorderSide(color: cs.primary, width: 1.4),
                  ),
            contentPadding: borderless
                ? const EdgeInsets.symmetric(vertical: 8)
                : const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        );
      },
    );
  }

  Widget _buildCompact(BuildContext context, ColorScheme cs) {
    final pill = OutlineInputBorder(
      borderRadius: BorderRadius.circular(999),
      borderSide: BorderSide.none,
    );
    return SizedBox(
      height: 40,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final showClear = value.text.isNotEmpty;
          return TextField(
            controller: controller,
            focusNode: focusNode,
            autofocus: autofocus,
            // 填满 40dp 胶囊：避免清除按钮出现/消失时高度跳变。
            expands: true,
            maxLines: null,
            minLines: null,
            textInputAction: TextInputAction.search,
            textAlignVertical: TextAlignVertical.center,
            onChanged: onChanged,
            onSubmitted: onSubmitted,
            style: Theme.of(context).textTheme.bodyMedium,
            decoration: InputDecoration(
              hintText: hintText,
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              prefixIconConstraints: const BoxConstraints(minWidth: 40),
              suffixIcon: showClear
                  ? IconButton(
                      onPressed: onClear,
                      icon: const Icon(Icons.cancel_rounded, size: 18),
                      tooltip: '清除搜索',
                      visualDensity: VisualDensity.compact,
                    )
                  : null,
              suffixIconConstraints: const BoxConstraints(
                minWidth: 40,
                minHeight: 40,
              ),
              filled: true,
              fillColor: cs.surfaceContainerHighest,
              border: pill,
              enabledBorder: pill,
              focusedBorder: pill,
              contentPadding: const EdgeInsets.only(right: 12),
            ),
          );
        },
      ),
    );
  }
}
