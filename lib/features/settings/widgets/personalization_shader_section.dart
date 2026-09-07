import 'package:flutter/material.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_icon_badge.dart';
import '../../../core/theme/personalization_controller.dart';
import 'shader_tuning_controls.dart';

/// 首页个性化 — Shader section（PRD FR-4 拆分）。
///
/// 平面化卡面：小节标题在卡外（13/w600/onSurfaceVariant），组内行由
/// hairline 分隔（outlineVariant @ 0.35，与行文字左对齐）。
class PersonalizationShaderSection extends StatelessWidget {
  const PersonalizationShaderSection({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const _SectionHeader('Shader'),
            const SizedBox(width: 8),
            Chip(
              label: const Text('性能开销大'),
              visualDensity: VisualDensity.compact,
              side: BorderSide.none,
              backgroundColor: cs.errorContainer.withValues(alpha: 0.72),
              labelStyle: TextStyle(color: cs.onErrorContainer, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 8),
        AppCard(
          padding: EdgeInsets.zero,
          child: ClipRRect(
            borderRadius: AppRadius.cardBorder,
            child: ValueListenableBuilder<bool>(
              valueListenable: PersonalizationController.instance.shaderEnabled,
              builder: (context, shaderEnabled, _) {
                return Column(
                  children: [
                    _SwitchRow(
                      icon: Icons.auto_awesome_outlined,
                      title: '启用背景 Shader',
                      subtitle: '对背景图进行 GPU 纹理重采样与风格化渲染',
                      value: shaderEnabled,
                      onChanged:
                          PersonalizationController.instance.setShaderEnabled,
                    ),
                    if (shaderEnabled) ...[
                      const _Hairline(),
                      const ShaderAnimationSpeedSlider(),
                      const ShaderStrengthSlider(),
                      const ShaderOpacitySlider(),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
        // 模式说明：仅保留流体纹理（无模式选择器）。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            '模式：流体纹理 — 对背景做块状取样并施加流体扰动，'
            '无背景图时以主题色渐变生成配色；动画会持续占用 GPU。',
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurfaceVariant,
              height: 1.4,
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
