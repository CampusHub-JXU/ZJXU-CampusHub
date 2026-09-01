import 'package:flutter/material.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/personalization_controller.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_icon_badge.dart';

/// 首页个性化 — 首页内容 section。
///
/// 首页正文内容的显隐开关（区别于背景/材质的外观项）：校徽水印、
/// 「今天」段落的全天课程形态。状态由 [PersonalizationController]
/// 持久化并被首页实时消费（ValueListenable 即时重建）。
///
/// 平面化卡面：小节标题在卡外（13/w600/onSurfaceVariant），组内行由
/// hairline 分隔，与玻璃材质 section 同一设计语言。
class PersonalizationHomeSection extends StatelessWidget {
  const PersonalizationHomeSection({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = PersonalizationController.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('首页内容'),
        const SizedBox(height: 8),
        AppCard(
          padding: EdgeInsets.zero,
          child: ClipRRect(
            borderRadius: AppRadius.cardBorder,
            child: Column(
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: controller.emblemWatermarkEnabled,
                  builder: (context, enabled, _) {
                    return _SwitchRow(
                      icon: Icons.workspace_premium_outlined,
                      title: '校徽水印',
                      subtitle: '在首页状态区右下角展示嘉兴大学校徽水印',
                      value: enabled,
                      onChanged: controller.setEmblemWatermarkEnabled,
                    );
                  },
                ),
                const _Hairline(),
                ValueListenableBuilder<bool>(
                  valueListenable: controller.fullDayCoursesEnabled,
                  builder: (context, enabled, _) {
                    return _SwitchRow(
                      icon: Icons.today_outlined,
                      title: '今日全部课程',
                      subtitle: '「今天」段落列出全天课程，已结束的灰显；关闭时仅显示剩余课程',
                      value: enabled,
                      onChanged: controller.setFullDayCoursesEnabled,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 小节标题：13/w600/onSurfaceVariant。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Text(
      title,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: cs.onSurfaceVariant,
        letterSpacing: 0.2,
      ),
    );
  }
}

/// 组内 hairline 分隔线：outlineVariant @ 0.35，左缩进与行文字对齐。
class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Divider(
      height: 1,
      thickness: 1,
      indent: 64,
      color: cs.outlineVariant.withValues(alpha: 0.35),
    );
  }
}

/// 开关行：延续 SwitchListTile 的「点行即切换」语义，样式并入平色行。
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              AppIconBadge(
                icon: icon,
                accentColor: cs.primary,
                size: AppIconBadgeSize.small,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                        height: 1.2,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Switch.adaptive(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}
