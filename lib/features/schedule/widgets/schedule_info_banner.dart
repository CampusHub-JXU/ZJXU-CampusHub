import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../shared/widgets/glass_container.dart';
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
    final cs = Theme.of(context).colorScheme;
    final parts = <String>[
      if ((message ?? '').isNotEmpty) message!,
      if (updatedAt != null) '最近更新 ${_formatDateTime(updatedAt!)}',
      if (!loggedIn && updatedAt != null) '当前仅展示缓存',
    ];

    if (parts.isEmpty) return const SizedBox.shrink();

    // 课表页模糊预算已满（顶栏 + 底栏），信息横幅使用纯 tint 卡（无模糊）。
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: GlassContainer(
        tier: GlassTier.card,
        blurred: false,
        width: double.infinity,
        borderRadius: BorderRadius.circular(AppRadius.input),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 15,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                parts.join(' · '),
                style: context.appText.meta.copyWith(height: 1.4),
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
