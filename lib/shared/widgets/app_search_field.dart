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
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final double fillAlpha;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final showClear = value.text.isNotEmpty;
        return TextField(
          controller: controller,
          textInputAction: TextInputAction.search,
          onChanged: onChanged,
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
}
