import 'package:flutter/material.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/glass_style_controller.dart';
import '../../../core/theme/surface_material.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_icon_badge.dart';
import '../../../core/theme/personalization_controller.dart';
import 'glass_preset_control.dart';

/// 首页个性化 — 玻璃材质 section。
///
/// 参数（开关/模糊强度/透明度）为全局材质设置，由
/// [GlassStyleController] 统一存储并被所有玻璃组件消费；
/// 「课表卡片毛玻璃」是首页头卡的独立布局开关，仍归 PersonalizationController。
///
/// 平面化卡面：小节标题在卡外（13/w600/onSurfaceVariant），组内行由
/// hairline 分隔（outlineVariant @ 0.35，与行文字左对齐）。
class PersonalizationGlassSection extends StatelessWidget {
  const PersonalizationGlassSection({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = GlassStyleController.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('玻璃材质'),
        const SizedBox(height: 8),
        AppCard(
          padding: EdgeInsets.zero,
          child: ClipRRect(
            borderRadius: AppRadius.cardBorder,
            child: Column(
              children: [
                _buildMaterialStyleSelector(context, style),
                const _Hairline(),
                ValueListenableBuilder<bool>(
                  valueListenable: style.enabled,
                  builder: (context, glassEnabled, _) {
                    return _SwitchRow(
                      icon: Icons.blur_on_outlined,
                      title: '玻璃材质（全局）',
                      subtitle: '关闭后所有玻璃表面降级为实色，低端机更流畅',
                      value: glassEnabled,
                      onChanged: (value) => style.setEnabled(value),
                    );
                  },
                ),
                const _Hairline(),
                ValueListenableBuilder<bool>(
                  valueListenable:
                      PersonalizationController.instance.headerGlassEnabled,
                  builder: (context, headerGlass, _) {
                    return _SwitchRow(
                      icon: Icons.blur_on_outlined,
                      title: '课表卡片毛玻璃',
                      subtitle: '背景图之上时对顶部课表卡片添加模糊',
                      value: headerGlass,
                      onChanged: PersonalizationController
                          .instance
                          .setHeaderGlassEnabled,
                    );
                  },
                ),
                _buildGlassBlurSlider(style),
                _buildGlassOpacitySlider(style),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            // 与新语义同步：材质风格决定渲染配方，
            // 模糊强度滑条同时作用于顶栏/底栏/弹层/玻璃卡片。
            '材质风格决定表面渲染方式；模糊强度与透明度统一作用于顶栏、底部导航、弹层与玻璃卡片',
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

  Widget _buildMaterialStyleSelector(
    BuildContext context,
    GlassStyleController style,
  ) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<SurfaceMaterialStyle>(
      valueListenable: style.materialStyle,
      builder: (context, selected, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '表面材质',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<SurfaceMaterialStyle>(
                  showSelectedIcon: false,
                  segments: [
                    for (final option in SurfaceMaterialStyle.values)
                      ButtonSegment<SurfaceMaterialStyle>(
                        value: option,
                        label: Text(option.label),
                      ),
                  ],
                  selected: {selected},
                  onSelectionChanged: (selection) =>
                      style.setMaterialStyle(selection.first),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                selected.description,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurfaceVariant,
                  height: 1.3,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGlassBlurSlider(GlassStyleController style) {
    return ValueListenableBuilder<double>(
      valueListenable: style.blurSigma,
      builder: (context, blur, _) {
        return GlassPresetControl(
          label: '模糊强度',
          value: blur,
          min: 0,
          max: 30,
          presets: const [0, 8, 14, 20, 28],
          decimals: 0,
          suffix: '',
          onPreview: (value) {
            style.blurSigma.value = value;
          },
          onCommit: style.setBlurSigma,
        );
      },
    );
  }

  Widget _buildGlassOpacitySlider(GlassStyleController style) {
    return ValueListenableBuilder<double>(
      valueListenable: style.tintOpacity,
      builder: (context, opacity, _) {
        return GlassPresetControl(
          label: '玻璃透明度',
          value: opacity,
          min: 0.2,
          max: 1.0,
          presets: const [0.36, 0.52, 0.68, 0.82, 0.94],
          decimals: 0,
          suffix: '%',
          displayMultiplier: 100,
          onPreview: (value) {
            style.tintOpacity.value = value;
          },
          onCommit: style.setTintOpacity,
        );
      },
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
