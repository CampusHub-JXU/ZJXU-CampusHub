import 'package:flutter/material.dart';

import '../../home/home_controller.dart';
import 'shader_tuning_controls.dart';

/// 首页个性化 — Shader section（PRD FR-4 拆分）。
class PersonalizationShaderSection extends StatelessWidget {
  const PersonalizationShaderSection({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
            child: Row(
              children: [
                Text('Shader', style: textTheme.titleSmall),
                const SizedBox(width: 8),
                Chip(
                  label: const Text('性能开销大'),
                  visualDensity: VisualDensity.compact,
                  side: BorderSide.none,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.errorContainer.withValues(alpha: 0.72),
                  labelStyle: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: HomeController.instance.shaderEnabled,
            builder: (context, shaderEnabled, _) {
              return Column(
                children: [
                  SwitchListTile.adaptive(
                    secondary: const Icon(Icons.auto_awesome_outlined),
                    title: const Text('启用背景 Shader'),
                    subtitle: const Text('对背景图进行 GPU 纹理重采样与风格化渲染'),
                    value: shaderEnabled,
                    onChanged: HomeController.instance.setShaderEnabled,
                  ),
                  if (shaderEnabled) ...[
                    _buildShaderModePicker(context, textTheme),
                    const ShaderAnimationSpeedSlider(),
                    const ShaderStrengthSlider(),
                    const ShaderOpacitySlider(),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildShaderModePicker(BuildContext context, TextTheme textTheme) {
    return ValueListenableBuilder<HomeShaderMode>(
      valueListenable: HomeController.instance.shaderMode,
      builder: (context, shaderMode, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text('Shader 模式', style: textTheme.bodySmall),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: SegmentedButton<HomeShaderMode>(
                segments: const [
                  ButtonSegment(
                    value: HomeShaderMode.glass,
                    icon: Icon(Icons.blur_on_outlined, size: 18),
                    label: Text('玻璃背景'),
                  ),
                  ButtonSegment(
                    value: HomeShaderMode.ribbon,
                    icon: Icon(Icons.waves_outlined, size: 18),
                    label: Text('流光丝带'),
                  ),
                  ButtonSegment(
                    value: HomeShaderMode.collage,
                    icon: Icon(Icons.auto_awesome_mosaic_outlined, size: 18),
                    label: Text('流体纹理'),
                  ),
                ],
                selected: {shaderMode},
                onSelectionChanged: (selection) {
                  HomeController.instance.setShaderMode(selection.first);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                switch (shaderMode) {
                  HomeShaderMode.ribbon =>
                    '保留原始流动丝带场，用背景图纹理为丝带着色并轻微混合主题色；动画会持续占用 GPU。',
                  HomeShaderMode.collage =>
                    '先将背景图切成细块取样，再用流体扰动场推移块状纹理，保留原图配色并产生液态形变；动画会持续占用 GPU。',
                  HomeShaderMode.glass =>
                    '将背景图作为纹理输入，柔焦雾化、轻微折射并混合当前主题色，适合搭配毛玻璃卡片。',
                },
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}