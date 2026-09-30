import 'package:flutter/material.dart';

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
    this.fillAlpha = 0.5,
    this.compact = false,
    this.autofocus = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final double fillAlpha;

  /// 紧凑胶囊形态：嵌入 AppBar 等窄高度位置，无描边、实色底。
  final bool compact;
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
          textInputAction: TextInputAction.search,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          decoration: InputDecoration(
            hintText: hintText,
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: showClear
                ? IconButton(
                    onPressed: onClear,
                    icon: const Icon(Icons.close_rounded),
                    tooltip: '清除搜索',
                  )
                : null,
            filled: true,
            fillColor: cs.surfaceContainerHighest.withValues(alpha: fillAlpha),
            border: OutlineInputBorder(
              borderRadius: AppRadius.inputBorder,
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: AppRadius.inputBorder,
              borderSide: BorderSide(
                color: cs.outlineVariant.withValues(alpha: 0.45),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: AppRadius.inputBorder,
              borderSide: BorderSide(color: cs.primary, width: 1.4),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
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
