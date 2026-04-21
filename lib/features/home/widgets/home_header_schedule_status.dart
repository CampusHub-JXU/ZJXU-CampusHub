import 'package:flutter/material.dart';

import '../../../app/theme.dart';

class HomeHeaderScheduleStatus extends StatelessWidget {
  const HomeHeaderScheduleStatus({
    super.key,
    required this.hasScheduleCache,
    required this.updatedAtText,
  });

  final bool hasScheduleCache;
  final String updatedAtText;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final active = hasScheduleCache;
    final value = active ? '课表更新于$updatedAtText' : '未更新';
    final background = isDark
        ? (active
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.06))
        : (active
              ? AppColors.primary.withValues(alpha: 0.1)
              : AppColors.primary.withValues(alpha: 0.05));
    final border = isDark
        ? (active
              ? Colors.white.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.1))
        : (active
              ? AppColors.primary.withValues(alpha: 0.16)
              : AppColors.primary.withValues(alpha: 0.08));
    final textColor = isDark
        ? Colors.white.withValues(alpha: active ? 0.92 : 0.72)
        : AppColors.primary.withValues(alpha: active ? 0.9 : 0.62);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Text(
        value,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: textColor,
        ),
      ),
    );
  }
}
