import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_surface_tokens.dart';
import '../../../core/theme/app_typography.dart';

class ScheduleInfoBanner extends StatelessWidget {
  const ScheduleInfoBanner({
    super.key,
    required this.message,
    required this.updatedAt,
    required this.loggedIn,
  });

  final String? message;
  final DateTime? updatedAt;
  final bool loggedIn;

  @override
  Widget build(BuildContext context) {
    final surfaces = context.appSurfaces;
    final parts = <String>[
      if ((message ?? '').isNotEmpty) message!,
      if (updatedAt != null) '最近更新 ${_formatDateTime(updatedAt!)}',
      if (!loggedIn && updatedAt != null) '当前仅展示缓存',
    ];

    if (parts.isEmpty) return const SizedBox.shrink();

    // 与课表编辑条一致的克制秩序条：全宽中性底面 + 细分割线衔接，
    // 不再用外层留白的圆角提示岛。课表页模糊预算已满（顶栏 + 底栏）。
    return DecoratedBox(
      decoration: BoxDecoration(
        color: surfaces.card,
        border: Border(
          bottom: BorderSide(color: surfaces.matrixLine, width: 0.7),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.pageMargin,
          vertical: 10,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                Icons.info_outline_rounded,
                size: 15,
                color: surfaces.ink2,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                parts.join(' · '),
                style: context.appText.meta.copyWith(
                  color: surfaces.ink2,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$month-$day $hour:$minute';
  }
}
